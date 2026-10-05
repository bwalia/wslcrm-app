#!/usr/bin/env python3
"""Seed the DBS Group demo workspace's online shop: a small AI-hardware catalogue and four quotes.

Runs after scripts/seed-dbs-limited.py, against the workspace it created, and reads the same env
file (default build/dbs-group-demo.env: WSL_API, WSL_NAMESPACE, WSL_PASSWORD, WSL_OTP, DBS_CLAIRE).

  1. As the owner (owen.sinclair): adds the `shop` module to the service_manager role, merged
     into its existing grants, so Claire and Marcus get the app's Shop tab. Engineers and the
     service desk stay without it.
  2. As Claire (service manager), through the shop admin API, so the server prices everything:
     - 4 categories, 6 products: a configurable AI workstation (CPU, up to two GPUs, memory,
       storage, PSU, with a power-budget rule) whose GPU options draw stock from two GPU products,
       a monitor, a support plan and a quote-only server. Stock is overwritten on every run;
       the stockless service and server get a low-stock alert of -1 so they never show as low.
     - 4 quotes: sent, draft with a per-line price override, accepted, and one already past its
       validity date (the server marks it expired). Dates are relative to today. Skipped if the
       workspace already has quotes, so a re-run never duplicates them.

Orders are not seeded: they only come from the shop website's Stripe checkout.

    scripts/seed-dbs-shop.py
    ENV_FILE=build/dbs-limited.env scripts/seed-dbs-shop.py     # the local stack's workspace

Customer emails use the reserved .example domain.
"""
from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ENV_FILE = Path(os.environ.get("ENV_FILE", ROOT / "build" / "dbs-group-demo.env"))
OWNER = "owen.sinclair"
SHOP_GRANT = ["create", "read", "update", "delete"]


def die(message: str) -> None:
    print(f"seed-dbs-shop: {message}", file=sys.stderr)
    sys.exit(1)


def read_env(path: Path) -> dict[str, str]:
    if not path.exists():
        die(f"{path} not found; run scripts/seed-dbs-limited.py first")
    env = {}
    for line in path.read_text().splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            key, value = line.split("=", 1)
            env[key.strip()] = value.strip().strip("'\"")
    env.update({k: v for k, v in os.environ.items() if k.startswith(("WSL_", "DBS_"))})
    for key in ("WSL_API", "WSL_NAMESPACE", "WSL_PASSWORD", "WSL_OTP", "DBS_CLAIRE"):
        if not env.get(key):
            die(f"{key} is missing from {path}")
    return env


class Session:
    def __init__(self, env: dict[str, str]):
        self.api = env["WSL_API"].rstrip("/")
        self.namespace = env["WSL_NAMESPACE"]
        self.password = env["WSL_PASSWORD"]
        self.otp = env["WSL_OTP"]
        self.tokens: dict[str, str] = {}

    def _request(self, method, path, token=None, body=None, form=None):
        headers = {"Accept": "application/json"}
        data = None
        if form is not None:
            data = urllib.parse.urlencode(form).encode()
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        elif body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        if token:
            headers["Authorization"] = f"Bearer {token}"
            headers["X-Namespace-Id"] = self.namespace
        req = urllib.request.Request(self.api + path, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                return resp.status, json.loads(resp.read() or b"null")
        except urllib.error.HTTPError as err:
            raw = err.read()
            try:
                return err.code, json.loads(raw)
            except ValueError:
                return err.code, raw.decode(errors="replace")[:300]

    def login(self, identifier: str) -> str:
        for _ in range(8):
            status, payload = self._request("POST", "/auth/login",
                                            form={"identifier": identifier, "password": self.password, "app_name": "wslcrm"})
            if status in (429, 502, 503):
                time.sleep(15)
                continue
            if status != 200 or not isinstance(payload, dict) or "session_token" not in payload:
                die(f"sign-in {identifier}: {status} {payload}")
            status, verified = self._request("POST", "/auth/2fa/verify",
                                             body={"session_token": payload["session_token"], "code": self.otp})
            if status in (429, 502, 503):
                time.sleep(15)
                continue
            if status != 200:
                die(f"2FA {identifier}: {status} {verified}")
            self.tokens[identifier] = verified["token"]
            return verified["token"]
        die(f"sign-in {identifier}: still rate-limited or unavailable")

    def call(self, who: str, method: str, path: str, body=None, ok=(200, 201)):
        token = self.tokens.get(who) or self.login(who)
        status, payload = self._request(method, path, token, body)
        if status == 401:
            status, payload = self._request(method, path, self.login(who), body)
        if status not in ok:
            die(f"{method} {path} as {who}: {status} {payload}")
        return payload


# ---------------------------------------------------------------------------------------------
# Catalogue

def option(code, name, delta, sort, default=False, max_qty=1, component=None, **attributes):
    o = {"code": code, "name": name, "price_delta_minor": delta, "is_default": default, "is_active": True,
         "sort_order": sort, "max_qty": max_qty, "attributes": attributes}
    if component:
        o["component_product_sku"] = component
    return o


def group(code, name, sort, options, selection="single", max_qty=1):
    return {"code": code, "name": name, "selection": selection, "required": True, "min_qty": 1,
            "max_qty": max_qty, "sort_order": sort, "options": options}


CATEGORIES = [
    {"slug": "workstations", "name": "AI workstations", "description": "Configurable towers for training and inference", "sort_order": 0},
    {"slug": "graphics-cards", "name": "Graphics cards", "description": "Data-centre and pro GPUs", "sort_order": 1},
    {"slug": "displays", "name": "Displays", "description": "Colour-accurate monitors", "sort_order": 2},
    {"slug": "services", "name": "Support & services", "description": "On-site cover and installation", "sort_order": 3},
]

BASE = {"currency": "GBP", "vat_rate": 0.2, "status": "active", "specs": {}, "attributes": {}, "images": [], "tags": []}

PRODUCTS = [
    # Component products first: the workstation's GPU options point at them by SKU.
    dict(BASE, sku="GPU-RTX5080", slug="nvidia-rtx-5080", name="NVIDIA GeForce RTX 5080 16 GB", brand="NVIDIA",
         product_type="gpu", price_mode="fixed", category_slug="graphics-cards", base_price_minor=109900,
         stock_qty=6, low_stock_threshold=2, lead_time_days=3, allow_backorder=True, price_verified=True,
         short_description="Fast 16 GB card for fine-tuning and local LLM inference",
         specs={"memory": "16 GB GDDR7", "tdp": "360 W"}, attributes={"watts": 360}, tags=["gpu", "inference"]),
    dict(BASE, sku="GPU-RTX6000ADA", slug="nvidia-rtx-6000-ada", name="NVIDIA RTX 6000 Ada 48 GB", brand="NVIDIA",
         product_type="gpu", price_mode="fixed", category_slug="graphics-cards", base_price_minor=649900,
         stock_qty=2, low_stock_threshold=2, lead_time_days=10, allow_backorder=True, price_verified=False,
         short_description="48 GB ECC workstation GPU for larger models",
         specs={"memory": "48 GB GDDR6 ECC", "tdp": "300 W"}, attributes={"watts": 300}, tags=["gpu", "training"]),
    dict(BASE, sku="MON-PA32UCX", slug="asus-proart-pa32ucx", name="ASUS ProArt PA32UCX 32\" 4K", brand="ASUS",
         product_type="peripheral", price_mode="fixed", category_slug="displays", base_price_minor=99900,
         stock_qty=4, low_stock_threshold=1, lead_time_days=5, allow_backorder=False, price_verified=True,
         short_description="Mini-LED HDR reference monitor",
         specs={"panel": "32\" IPS mini-LED", "resolution": "3840 × 2160"}),
    dict(BASE, sku="SVC-ONSITE-3Y", slug="onsite-support-3y", name="3-year on-site support", brand="DBS Group",
         product_type="service", price_mode="fixed", category_slug="services", base_price_minor=49900,
         stock_qty=0, low_stock_threshold=-1, lead_time_days=0, allow_backorder=True, price_verified=True,
         short_description="Next-business-day engineer visit anywhere in mainland UK"),
    dict(BASE, sku="SRV-EDGE-S1", slug="dbs-edge-inference-s1", name="DBS Edge Inference Server S1", brand="DBS Group",
         product_type="server", price_mode="quote_only", category_slug="workstations", base_price_minor=0,
         stock_qty=0, low_stock_threshold=-1, lead_time_days=21, allow_backorder=True, price_verified=False,
         short_description="2U, up to four GPUs, built to order — priced on request"),
    dict(BASE, sku="WS-AI-W7", slug="dbs-ai-workstation-w7", name="DBS AI Workstation W7", brand="DBS Group",
         product_type="workstation", price_mode="configurable", category_slug="workstations", base_price_minor=249900,
         stock_qty=3, low_stock_threshold=1, lead_time_days=7, allow_backorder=True, price_verified=True,
         is_featured=True, short_description="Quiet tower for training, fine-tuning and 4K editing",
         specs={"chassis": "Fractal Design North XL", "cooling": "360 mm AIO", "warranty": "3 years RTB"},
         tags=["ai", "workstation"],
         option_groups=[
             group("cpu", "Processor", 0, [
                 option("tr-7960x", "AMD Threadripper 7960X (24 cores)", 0, 0, True, watts=350),
                 option("tr-7980x", "AMD Threadripper 7980X (64 cores)", 260000, 1, watts=350)]),
             group("gpu", "Graphics", 1, [
                 option("rtx-5080", "RTX 5080 16 GB", 109900, 0, True, max_qty=2, component="GPU-RTX5080", watts=360),
                 option("rtx-6000-ada", "RTX 6000 Ada 48 GB", 649900, 1, max_qty=2, component="GPU-RTX6000ADA", watts=300)],
                 selection="multi", max_qty=2),
             group("memory", "Memory", 2, [
                 option("ddr5-128", "128 GB DDR5 ECC", 0, 0, True),
                 option("ddr5-256", "256 GB DDR5 ECC", 62000, 1)]),
             group("storage", "Storage", 3, [
                 option("nvme-2tb", "2 TB NVMe Gen5", 0, 0, True),
                 option("nvme-4tb", "4 TB NVMe Gen5", 24000, 1),
                 option("nvme-8tb", "8 TB NVMe Gen5 (2 × 4 TB)", 52000, 2)]),
             group("psu", "Power supply", 4, [
                 option("psu-1300", "1300 W Platinum", 0, 0, True, psu_watts=1300),
                 option("psu-1600", "1600 W Titanium", 18000, 1, psu_watts=1600)]),
         ],
         rules=[{"kind": "power", "message": "Choose a bigger power supply for this CPU and GPU combination.",
                 "is_active": True,
                 "params": {"budget_from": "psu", "budget_attr": "psu_watts", "sum_attr": "watts",
                            "groups": ["cpu", "gpu"], "base_watts": 250, "headroom": 0.9}}]),
]


# ---------------------------------------------------------------------------------------------
# Quotes

def selections(**groups):
    return {code: [{"option": o, "qty": q} for o, q in chosen] for code, chosen in groups.items()}


def end_of_day(days_from_now: int) -> str:
    day = datetime.now(timezone.utc) + timedelta(days=days_from_now)
    return day.strftime("%Y-%m-%d 23:59:59")


def quotes():
    return [
        {"status": "sent", "valid_until": end_of_day(30), "shipping_minor": 0,
         "customer": {"name": "Priya Nair", "email": "priya.nair@northwind-imaging.example", "company": "Northwind Imaging Ltd",
                      "phone": "0113 496 0712",
                      "address": {"line1": "4 Wellington Place", "city": "Leeds", "postal_code": "LS1 4AP", "country": "GB"}},
         "notes": "Two training workstations with dual RTX 5080, as discussed. Delivery and set-up included.",
         "internal_notes": "Follow up Thursday; they're comparing with Scan.",
         "lines": [{"product_slug": "dbs-ai-workstation-w7", "qty": 2,
                    "selections": selections(cpu=[("tr-7980x", 1)], gpu=[("rtx-5080", 2)], memory=[("ddr5-256", 1)],
                                             storage=[("nvme-4tb", 1)], psu=[("psu-1600", 1)])},
                   {"product_slug": "asus-proart-pa32ucx", "qty": 2, "selections": {}},
                   {"product_slug": "onsite-support-3y", "qty": 2, "selections": {}}]},
        {"status": "draft", "valid_until": end_of_day(45), "shipping_minor": 4500,
         "customer": {"name": "Dr Tom Okafor", "email": "t.okafor@leeds-research.example", "company": "Leeds Clinical Research Unit"},
         "notes": "Academic pricing applied to the workstation.",
         "internal_notes": "Price agreed with Marcus — 8% off list.",
         "lines": [{"product_slug": "dbs-ai-workstation-w7", "qty": 1, "price_override_minor": 830000,
                    "selections": selections(cpu=[("tr-7960x", 1)], gpu=[("rtx-6000-ada", 1)], memory=[("ddr5-256", 1)],
                                             storage=[("nvme-8tb", 1)], psu=[("psu-1300", 1)])}]},
        {"status": "accepted", "valid_until": end_of_day(20), "shipping_minor": 2500,
         "customer": {"name": "Sam Whitfield", "email": "sam@harbour-analytics.example", "company": "Harbour Analytics"},
         "notes": "Four cards for the existing rack servers.",
         "lines": [{"product_slug": "nvidia-rtx-5080", "qty": 4, "selections": {}}]},
        # Past its date: the server reports it expired.
        {"status": "sent", "valid_until": end_of_day(-5), "shipping_minor": 0,
         "customer": {"name": "Hannah Cole", "email": "hannah.cole@brightside-vfx.example", "company": "Brightside VFX"},
         "notes": "Single editing workstation.",
         "lines": [{"product_slug": "dbs-ai-workstation-w7", "qty": 1,
                    "selections": selections(cpu=[("tr-7960x", 1)], gpu=[("rtx-5080", 1)], memory=[("ddr5-128", 1)],
                                             storage=[("nvme-2tb", 1)], psu=[("psu-1300", 1)])},
                   {"product_slug": "asus-proart-pa32ucx", "qty": 1, "selections": {}}]},
    ]


# ---------------------------------------------------------------------------------------------

def grant_shop_to_service_managers(s: Session) -> None:
    payload = s.call(OWNER, "GET", "/api/v2/namespace/roles")
    rows = payload.get("data", payload) if isinstance(payload, dict) else payload
    if isinstance(rows, dict):
        rows = rows.get("roles") or rows.get("data") or []
    role = next((r for r in rows if r.get("role_name") == "service_manager"), None)
    if not role:
        die("no service_manager role; run scripts/seed-dbs-limited.py first")
    permissions = role.get("permissions") or {}
    if isinstance(permissions, str):
        permissions = json.loads(permissions)
    if set(SHOP_GRANT) <= set(permissions.get("shop", [])):
        print("service_manager already has shop")
        return
    # PUT replaces the whole map, so send every existing grant back with shop added.
    permissions["shop"] = SHOP_GRANT
    s.call(OWNER, "PUT", f"/api/v2/namespace/roles/{role['uuid']}", {"permissions": permissions})
    print("granted shop to service_manager")


def main() -> None:
    env = read_env(ENV_FILE)
    s = Session(env)
    manager = env["DBS_CLAIRE"]
    shop = "/api/v2/shop/admin"

    grant_shop_to_service_managers(s)

    result = s.call(manager, "POST", f"{shop}/import",
                    {"categories": CATEGORIES, "products": PRODUCTS, "overwrite_stock": True})["data"]
    print("catalogue:", json.dumps({k: result[k] for k in ("categories", "products")}))
    if result.get("errors"):
        die(f"import errors: {result['errors']}")

    existing = s.call(manager, "GET", f"{shop}/quotes?limit=1")["meta"]["total"]
    if existing:
        print(f"quotes: {existing} already in the workspace; not adding more")
        return
    for body in quotes():
        q = s.call(manager, "POST", f"{shop}/quotes", dict(body, source="admin"))["data"]
        print(f"quote {q['quote_number']}  {q['status']:<8}  {q['customer'].get('company')}  £{q['total_minor'] / 100:,.2f}")


if __name__ == "__main__":
    main()
