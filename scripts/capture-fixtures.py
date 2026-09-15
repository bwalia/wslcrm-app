#!/usr/bin/env python3
"""Capture real OpsAPI responses as test fixtures.

Logs in (with 2FA), selects a namespace, fetches read-only endpoints and writes
anonymised JSON into WSLCRMTests/Fixtures/live/. Apart from login, 2FA verify and
logout of its own session, only GET requests are made — nothing is created or changed.

Usage:
    scripts/capture-fixtures.py [--base https://int-opsapi.workstation.co.uk]

Credentials come from WSL Vault — run it as `scripts/vault-env.py exec -- scripts/capture-fixtures.py`
so WSL_IDENTIFIER / WSL_PASSWORD are injected without touching disk. A git-ignored .env
(e.g. from `scripts/vault-env.py write-env`) or interactive prompts also work. They are never written to disk.
The emailed 2FA code is read from WSL_OTP, else from the file scripts/.capture/otp
(polled for up to 5 minutes, then deleted), else an interactive prompt. Set
WSL_NAMESPACE to a namespace uuid/slug to skip the namespace prompt. Personal data (names, emails, phones, addresses, notes) is
replaced with placeholders while keeping keys, types and nulls intact, so the
fixtures still exercise the decoders faithfully.
"""
import argparse
import getpass
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "WSLCRMTests", "Fixtures", "live")

# (fixture name, path, needs first-item uuid from another fixture?)
LIST_ENDPOINTS = [
    ("auth_me", "/auth/me"),
    ("user_namespaces", "/api/v2/user/namespaces"),
    ("user_menu", "/api/v2/user/menu"),
    ("fs_jobs_list", "/api/v2/field-service/jobs?page=1&per_page=5"),
    ("fs_visits_mine", "/api/v2/field-service/visits?mine=true&page=1&per_page=5"),
    ("fs_service_requests_list", "/api/v2/field-service/service-requests?page=1&per_page=5"),
    ("fs_stats", "/api/v2/field-service/stats"),
    ("fs_engineers", "/api/v2/field-service/engineers"),
    ("fs_job_types", "/api/v2/field-service/job-types"),
    ("crm_accounts_list", "/api/v2/crm/accounts?page=1&per_page=5"),
    ("crm_contacts_list", "/api/v2/crm/contacts?page=1&per_page=5"),
    ("crm_deals_list", "/api/v2/crm/deals?page=1&per_page=5"),
    ("crm_pipelines", "/api/v2/crm/pipelines"),
    ("crm_dashboard_stats", "/api/v2/crm/dashboard/stats"),
    ("customers_list", "/api/v2/customers?page=1&perPage=5"),
    ("products_list", "/api/v2/products?page=1&perPage=5"),
    ("my_stores", "/api/v2/my/stores"),
    ("orders_list", "/api/v2/orders?page=1&per_page=5"),
    ("orders_stats", "/api/v2/orders/stats"),
    ("invoices_list", "/api/v2/invoices?page=1&perPage=5"),
    ("invoices_stats", "/api/v2/invoices/dashboard/stats"),
    ("invoices_tax_rates", "/api/v2/invoices/tax-rates"),
]

# (fixture name, list fixture to take the first item from, path template, id key)
DETAIL_ENDPOINTS = [
    ("fs_job_detail", "fs_jobs_list", "/api/v2/field-service/jobs/{}", "uuid"),
    ("fs_visit_detail", "fs_visits_mine", "/api/v2/field-service/visits/{}", "uuid"),
    ("fs_service_request_detail", "fs_service_requests_list", "/api/v2/field-service/service-requests/{}", "uuid"),
    ("crm_account_detail", "crm_accounts_list", "/api/v2/crm/accounts/{}", "uuid"),
    ("crm_deal_detail", "crm_deals_list", "/api/v2/crm/deals/{}", "uuid"),
    ("customer_detail", "customers_list", "/api/v2/customers/{}", "uuid"),
    ("product_detail", "products_list", "/api/v2/products/{}", "uuid"),
    ("order_status_history", "orders_list", "/api/v2/orders/{}/status-history", "uuid"),
    ("invoice_detail", "invoices_list", "/api/v2/invoices/{}", "uuid"),
]

PII_STRING_KEYS = {
    "email", "customer_email", "contact_email", "billing_email", "site_contact_email",
    "phone", "mobile", "telephone", "customer_phone", "contact_phone", "site_contact_phone",
    "first_name", "last_name", "full_name", "display_name", "contact_name", "customer_name",
    "site_contact_name", "signoff_name", "customer_signoff_name", "engineer_name", "assigned_to_name",
    "address", "address_line1", "address_line2", "address_line_1", "address_line_2", "street",
    "site_address", "billing_address", "shipping_address", "postcode", "post_code", "zip",
    "notes", "work_report", "description", "internal_notes", "complaint", "details",
    "username", "avatar", "avatar_url", "profile_picture",
}
SECRET_KEYS = {"token", "refresh_token", "session_token", "password", "api_key", "secret"}
EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")


def anonymise(value, key=None):
    if isinstance(value, dict):
        return {k: anonymise(v, k) for k, v in value.items()}
    if isinstance(value, list):
        return [anonymise(v, key) for v in value]
    if isinstance(value, str):
        k = (key or "").lower()
        if k in SECRET_KEYS:
            return "redacted"
        if k in PII_STRING_KEYS or k.endswith("_email") or k.endswith("_phone"):
            if "email" in k:
                return "person@example.com"
            if "phone" in k or k in {"mobile", "telephone"}:
                return "+44 20 7946 0000"
            if "postcode" in k or k in {"post_code", "zip"}:
                return "SW1A 1AA"
            return "Sample " + k.replace("_", " ")
        return EMAIL_RE.sub("person@example.com", value)
    return value


def request(base, path, method="GET", body=None, token=None, namespace=None, form=None):
    headers = {"Accept": "application/json", "User-Agent": "WSLCRM-fixture-capture"}
    data = None
    if form is not None:
        # /auth/login only parses form bodies.
        data = urllib.parse.urlencode(form, quote_via=urllib.parse.quote).encode()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    elif body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = "Bearer " + token
    if namespace:
        headers["X-Namespace-Id"] = namespace
    req = urllib.request.Request(base + path, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, json.loads(resp.read() or b"null")
    except urllib.error.HTTPError as err:
        raw = err.read()
        try:
            return err.code, json.loads(raw)
        except ValueError:
            return err.code, {"_raw": raw.decode(errors="replace")[:500]}


def save(name, status, payload):
    os.makedirs(OUT, exist_ok=True)
    # Prefixed so they never collide with the hand-written fixtures in the flat test bundle.
    path = os.path.join(OUT, "live_" + name + ".json")
    with open(path, "w") as fh:
        json.dump(anonymise(payload), fh, indent=2, sort_keys=True)
        fh.write("\n")
    print(f"  {status}  live_{name}.json")


def first_item(payload, key):
    data = payload.get("data") if isinstance(payload, dict) else None
    if isinstance(data, dict):
        for candidate in ("items", "data", "jobs", "visits", "records"):
            if isinstance(data.get(candidate), list):
                data = data[candidate]
                break
    if isinstance(data, list) and data and isinstance(data[0], dict):
        return data[0].get(key) or data[0].get("uuid") or data[0].get("id")
    return None


def load_dotenv():
    path = os.path.join(ROOT, ".env")
    if not os.path.exists(path):
        return
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                value = value.strip()
                if value.startswith('"'):
                    try:
                        value = json.loads(value)  # scripts/vault-env.py write-env quotes as JSON
                    except ValueError:
                        value = value.strip('"')
                os.environ.setdefault(key.strip(), value.strip("'") if value.startswith("'") else value)


def read_otp(email):
    if os.environ.get("WSL_OTP"):
        return os.environ["WSL_OTP"].strip()
    otp_file = os.path.join(ROOT, "scripts", ".capture", "otp")
    if not sys.stdin.isatty():
        os.makedirs(os.path.dirname(otp_file), exist_ok=True)
        print(f"Waiting for the 2FA code sent to {email}: write it to {os.path.relpath(otp_file, ROOT)}", flush=True)
        deadline = time.time() + 300
        while time.time() < deadline:
            if os.path.exists(otp_file):
                with open(otp_file) as fh:
                    code = fh.read().strip()
                os.remove(otp_file)
                if code:
                    return code
            time.sleep(2)
        sys.exit("Timed out waiting for the 2FA code.")
    return input(f"2FA code sent to {email}: ").strip()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="https://int-opsapi.workstation.co.uk")
    args = parser.parse_args()
    base = args.base.rstrip("/")

    load_dotenv()
    identifier = os.environ.get("WSL_IDENTIFIER") or input("Email or username: ")
    password = os.environ.get("WSL_PASSWORD") or getpass.getpass("Password: ")

    status, login = request(base, "/auth/login", "POST",
                            form={"identifier": identifier, "password": password, "app_name": "WSLCRM"})
    save("auth_login_requires_2fa", status, login)
    if status != 200 or not isinstance(login, dict):
        sys.exit(f"Login failed ({status}): {login}")

    token = login.get("token")
    namespaces = login.get("namespaces") or []
    verified_payload = None
    if login.get("requires_2fa"):
        code = read_otp(login.get("email", "your email"))
        status, verified = request(base, "/auth/2fa/verify", "POST",
                                   {"session_token": login.get("session_token"), "code": code})
        save("auth_2fa_verify", status, verified)
        if status != 200:
            sys.exit(f"2FA failed ({status}): {verified}")
        token = verified.get("token")
        namespaces = verified.get("namespaces") or []
        verified_payload = verified

    if not namespaces:
        sys.exit("No namespaces returned for this user.")
    for i, ns in enumerate(namespaces):
        print(f"  [{i}] {ns.get('name') or ns.get('slug')}  ({ns.get('uuid')})")
    wanted = os.environ.get("WSL_NAMESPACE")
    if wanted:
        ns = next((n for n in namespaces if wanted in (n.get("uuid"), n.get("slug"))), namespaces[0])
    elif sys.stdin.isatty():
        ns = namespaces[int(input("Namespace to capture [0]: ").strip() or "0")]
    else:
        ns = namespaces[0]
    namespace = ns.get("uuid")
    print(f"Using namespace {ns.get('name')}")

    captured = {}
    print("Capturing list endpoints…")
    for name, path in LIST_ENDPOINTS:
        status, payload = request(base, path, token=token, namespace=namespace)
        captured[name] = payload
        save(name, status, payload)

    print("Capturing detail endpoints…")
    for name, source, template, key in DETAIL_ENDPOINTS:
        ident = first_item(captured.get(source) or {}, key)
        if not ident:
            print(f"  --  {name}: no items in {source}, skipped")
            continue
        status, payload = request(base, template.format(ident), token=token, namespace=namespace)
        save(name, status, payload)

    # Error shapes (no side effects).
    status, payload = request(base, "/api/v2/field-service/jobs", token="invalid", namespace=namespace)
    save("error_invalid_token", status, payload)
    status, payload = request(base, "/api/v2/field-service/jobs/00000000-0000-0000-0000-000000000000",
                              token=token, namespace=namespace)
    save("error_not_found", status, payload)

    status, payload = request(base, "/auth/refresh", "POST", {"refresh_token": "not-a-real-token"})
    save("error_refresh_invalid", status, payload)

    # Revoke the capture session's refresh token.
    if isinstance(verified_payload, dict) and verified_payload.get("refresh_token"):
        request(base, "/auth/logout", "POST", {"refresh_token": verified_payload["refresh_token"]})
    print(f"Done. Review {os.path.relpath(OUT, ROOT)} before committing.")


if __name__ == "__main__":
    main()
