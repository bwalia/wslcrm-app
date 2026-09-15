#!/usr/bin/env python3
"""Load WSLCRM's local secrets (int test credentials) from WSL Vault.

The secret is a flat KV v2 map of ENV_NAME -> value, the same layout ExternalSecrets
`dataFrom.extract` uses for the platform's services, e.g.:

    WSL_IDENTIFIER   engineer@example.com
    WSL_PASSWORD     …
    WSL_NAMESPACE    <optional namespace uuid or slug>
    WSL_OTP          <optional; only if int has TEST_OTP_CODE>

Usage:
    # Recommended: secrets go straight into the child process, nothing touches disk.
    scripts/vault-env.py exec -- scripts/capture-fixtures.py

    # Or materialise a git-ignored .env (mode 600) for tools that need a file.
    scripts/vault-env.py write-env

    # Show which keys the secret holds (never the values).
    scripts/vault-env.py keys

Vault connection (first match wins):
    --addr / WSLVAULT_ADDR / ~/.wslvault/config.toml `endpoint`   (default https://vault.workstation.co.uk)
    --token / WSLVAULT_TOKEN / config.toml `token`
    WSLVAULT_API_KEY (exchanged at /v1/auth/api-key; TOTP from WSLVAULT_TOTP or a prompt if MFA is required)
    --tenant-id / WSLVAULT_TENANT_ID / config.toml `tenant_id`
    WSLVAULT_PROFILE selects a [profiles.<name>] section of config.toml.
Secret location:
    --mount / WSLCRM_VAULT_MOUNT (default "kv"), --path / WSLCRM_VAULT_PATH (default "wslcrm/int/app").
"""
import argparse
import getpass
import json
import os
import re
import stat
import sys
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_ADDR = "https://vault.workstation.co.uk"
DEFAULT_MOUNT = "kv"
DEFAULT_PATH = "wslcrm/int/app"
ENV_NAME = re.compile(r"^[A-Z_][A-Z0-9_]*$")


def read_config_toml():
    """Minimal reader for ~/.wslvault/config.toml: top-level keys and [profiles.<name>] tables."""
    path = os.path.expanduser("~/.wslvault/config.toml")
    if not os.path.exists(path):
        return {}
    top, profiles, current = {}, {}, top
    with open(path) as fh:
        for raw in fh:
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue
            section = re.match(r"^\[profiles\.([^\]]+)\]$", line)
            if section:
                current = profiles.setdefault(section.group(1), {})
                continue
            if line.startswith("["):
                current = {}
                continue
            if "=" in line:
                key, value = line.split("=", 1)
                current[key.strip()] = value.strip().strip('"').strip("'")
    profile = os.environ.get("WSLVAULT_PROFILE")
    merged = dict(top)
    if profile and profile in profiles:
        merged.update(profiles[profile])
    return merged


def http(method, url, headers, body=None):
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(url, data=data, method=method, headers={
        "Accept": "application/json", "Content-Type": "application/json", **headers})
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return response.status, json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as error:
        raw = error.read()
        try:
            return error.code, json.loads(raw)
        except ValueError:
            return error.code, {"errors": [raw.decode(errors="replace")[:200]]}
    except urllib.error.URLError as error:
        sys.exit(f"Cannot reach WSL Vault at {url.split('/v1/')[0]}: {error.reason}")


def resolve_token(addr, tenant, cli_token, config):
    token = cli_token or os.environ.get("WSLVAULT_TOKEN") or config.get("token")
    if token:
        return token
    api_key = os.environ.get("WSLVAULT_API_KEY")
    if not api_key:
        sys.exit("No WSL Vault credentials. Set WSLVAULT_TOKEN (or WSLVAULT_API_KEY), "
                 "or run `wslvault init` to write ~/.wslvault/config.toml.")
    headers = {"X-Vault-Tenant-ID": tenant} if tenant else {}
    status, body = http("POST", f"{addr}/v1/auth/api-key", headers, {"api_key": api_key})
    if status == 200 and body.get("mfa_required"):
        code = os.environ.get("WSLVAULT_TOTP") or (sys.stdin.isatty() and getpass.getpass("WSL Vault TOTP code: "))
        if not code:
            sys.exit("This API key requires MFA: set WSLVAULT_TOTP or run interactively.")
        status, body = http("POST", f"{addr}/v1/auth/mfa/totp", headers, {"challenge": body.get("challenge"), "code": code})
    token = (body.get("auth") or {}).get("client_token") or body.get("token") or body.get("client_token")
    if status != 200 or not token:
        sys.exit(f"WSL Vault API-key login failed ({status}): {body.get('errors') or body.get('error') or 'no token returned'}")
    return token


def fetch_secret(args):
    config = read_config_toml()
    addr = (args.addr or os.environ.get("WSLVAULT_ADDR") or config.get("endpoint") or DEFAULT_ADDR).rstrip("/")
    tenant = args.tenant_id or os.environ.get("WSLVAULT_TENANT_ID") or config.get("tenant_id")
    mount = args.mount or os.environ.get("WSLCRM_VAULT_MOUNT") or DEFAULT_MOUNT
    path = (args.path or os.environ.get("WSLCRM_VAULT_PATH") or DEFAULT_PATH).strip("/")
    token = resolve_token(addr, tenant, args.token, config)

    headers = {"X-Vault-Token": token}
    if tenant:
        headers["X-Vault-Tenant-ID"] = tenant
    status, body = http("GET", f"{addr}/v1/{mount}/data/{path}", headers)
    if status == 404:
        sys.exit(f"No secret at {mount}/{path} (404). Check WSLCRM_VAULT_PATH / WSLCRM_VAULT_MOUNT.")
    if status in (401, 403):
        sys.exit(f"WSL Vault denied access to {mount}/{path} ({status}): {body.get('errors') or body.get('error')}")
    if status != 200:
        sys.exit(f"WSL Vault returned {status} for {mount}/{path}: {body.get('errors') or body.get('error')}")

    # KV v2: {"data": {"data": {...}, "metadata": {...}}}; tolerate a flattened {"data": {...}} too.
    data = body.get("data") or {}
    if isinstance(data.get("data"), dict):
        data = data["data"]
    secrets = {k: str(v) for k, v in data.items() if ENV_NAME.match(k) and v is not None}
    if not secrets:
        sys.exit(f"The secret at {mount}/{path} has no ENV_NAME-style keys.")
    return secrets, f"{mount}/{path}"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--addr")
    parser.add_argument("--token")
    parser.add_argument("--tenant-id")
    parser.add_argument("--mount")
    parser.add_argument("--path")
    sub = parser.add_subparsers(dest="command", required=True)
    run = sub.add_parser("exec", help="run a command with the secrets in its environment")
    run.add_argument("argv", nargs=argparse.REMAINDER)
    sub.add_parser("write-env", help="write a git-ignored .env (mode 600)")
    sub.add_parser("keys", help="list key names only")
    args = parser.parse_args()

    secrets, location = fetch_secret(args)
    names = ", ".join(sorted(secrets))

    if args.command == "keys":
        print(f"{location}: {names}")
    elif args.command == "write-env":
        path = os.path.join(ROOT, ".env")
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, stat.S_IRUSR | stat.S_IWUSR)
        with os.fdopen(fd, "w") as fh:
            fh.write(f"# Generated from WSL Vault {location} by scripts/vault-env.py — do not commit.\n")
            for key in sorted(secrets):
                fh.write(f"{key}={json.dumps(secrets[key])}\n")
        os.chmod(path, 0o600)
        print(f"Wrote .env from {location} ({names})")
    else:
        argv = args.argv[1:] if args.argv[:1] == ["--"] else args.argv
        if not argv:
            sys.exit("Usage: scripts/vault-env.py exec -- <command> [args…]")
        env = dict(os.environ)
        env.update(secrets)
        print(f"Loaded {names} from WSL Vault {location}", file=sys.stderr)
        os.execvpe(argv[0], argv, env)


if __name__ == "__main__":
    main()
