#!/usr/bin/env python3
"""Seed a Property Deals workspace, "Demo Buyers Ltd", with the SPEC §5 scenario.

A property buyer (guaranteed-sale model) in York: an owner, a manager and an operator. The
operator's day opens on what SPEC §5 describes:

- 7 Mill Lane at Searches, target completion in 9 working days, a £500/day late penalty capped
  at 20 days. The EPC booking task (60-minute SLA) is overdue, so the manager has been told and
  the deal is red with money at risk.
- The seller's solicitor last replied 50 hours ago and has 2 open enquiries.
- Exchange is blocked: the buyer's AML check isn't done.
- A chase email to the solicitor waits in the operator's Approvals inbox (asked for by the manager,
  so the operator can decide it).
- A second deal, 22 Station Road, a few weeks out, being renovated: a kanban board of build jobs
  and a purchase order to the kitchen supplier for it.
- A hot lead: Pat Keen replied on WhatsApp asking for a visit, so there's a "call now" task.

Everything goes through the real API as the person who would do it; the only SQL is creating the
owner's login, activating staff, and moving the EPC task's clock back an hour (time passing).

Uses the same machinery as scripts/seed-dbs-limited.py (read its docstring): local Docker by
default, or a cluster with KUBE_NAMESPACE / PG_POD / API_POD / DB / API set (see the README's
"Seeding the demo into int"). The server needs TEST_OTP_CODE (non-production only). Staff emails
end in @e2e.invalid so no sign-in codes are emailed.

    WSL_PASSWORD='…' scripts/seed-property-deals.py

Safe to re-run: people and the workspace are reused, and the scenario is only built once.
Writes build/<slug>.env (mode 600, git-ignored) with the sign-in details.
"""
from __future__ import annotations

import datetime
import importlib.util
import json
import os
import sys
from pathlib import Path
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("seed_dbs", ROOT / "scripts" / "seed-dbs-limited.py")
dbs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dbs)
sql, sql_value, lit, die, APIFailure = dbs.sql, dbs.sql_value, dbs.lit, dbs.die, dbs.APIFailure

SLUG = os.environ.get("PD_NAMESPACE_SLUG", "demo-buyers-ltd")
NAME = os.environ.get("PD_NAMESPACE_NAME", "Demo Buyers Ltd")
P = "/api/v2/property-deals"
YORK = ZoneInfo("Europe/London")

# key, first, last, username, workspace role (None: the owner)
PEOPLE = [
    ("owner", "Jordan", "Hale", "pd.owner", None),
    ("manager", "Priya", "Shah", "pd.manager", "pd_manager"),
    ("operator", "Sam", "Okafor", "pd.operator", "pd_operator"),
]


# Core modules the workspace uses alongside the Property Deals plugin (which has its own switch).
# Sales and billing are in too: customers order online (the Shop storefront), and the back office
# takes orders and payments and raises invoices from the dashboard. Payments live on invoices, so
# "payments" has no sidebar item but has to be on for the Roles page to grant it.
SALES = ["orders", "invoices", "payments", "purchase_orders", "products", "stores", "shop"]
MODULES = ["dashboard", "crm", "crm_leads", "customers", "projects", "document_templates", "reports",
           "activity", "chat", "users", "roles", "settings", "namespace", "plugins", "webhooks", "api-keys",
           *SALES]
# The back office (the Property Deals manager) runs sales and billing as well as deals.
BACK_OFFICE_ROLE = "pd_manager"
BACK_OFFICE_GRANTS = {"customers": ["manage"], **{module: ["manage"] for module in SALES}}


def email(username: str) -> str:
    return f"{username}@e2e.invalid"


def people_and_workspace(s) -> None:
    print("1. Owner and workspace")
    _, first, last, username, _ = PEOPLE[0]
    sql(f"""
        INSERT INTO users (uuid, first_name, last_name, email, username, password, active, created_at, updated_at)
        SELECT gen_random_uuid()::text, {lit(first)}, {lit(last)}, {lit(email(username))}, {lit(username)},
               crypt({lit(s.password)}, gen_salt('bf', 10)), true, NOW(), NOW()
        WHERE NOT EXISTS (SELECT 1 FROM users WHERE email = {lit(email(username))});
        UPDATE users SET password = crypt({lit(s.password)}, gen_salt('bf', 10)), active = true
        WHERE email = {lit(email(username))};""")
    for key, _, _, user, _ in PEOPLE:
        s.identifiers[key] = user
    ns = sql(f"SELECT uuid, id FROM namespaces WHERE slug = {lit(SLUG)}")
    if not ns:
        created = s.call("owner", "POST", "/api/v2/user/namespaces", {"name": NAME, "slug": SLUG})
        uuid = (created.get("namespace") or created.get("data") or created)["uuid"]
        s.call("owner", "PUT", "/api/v2/user/namespace-settings", {"default_namespace_id": uuid})
        system_ns = sql_value("SELECT uuid FROM namespaces WHERE slug = 'system'")
        if system_ns:   # undo the resolver's auto-join of a brand-new user into System
            s.ns_uuid = system_ns
            s.call("owner", "POST", "/api/v2/namespace/leave", {}, ok=(200, 201, 400, 403, 404))
        ns = sql(f"SELECT uuid, id FROM namespaces WHERE slug = {lit(SLUG)}")
    s.ns_uuid, s.ns_id = ns[0][0], int(ns[0][1])

    print("2. Modules: a property buyer's, not field service, tax or care")
    # The web home page picks its widgets from the business type (opsapi #713): deals, hot leads,
    # renovations and money at risk rather than shop cards.
    try:
        s.call("owner", "PUT", "/api/v2/namespace", {"business_type": "property_portfolio_manager"})
    except APIFailure as error:   # a server without the #713 migration answers 500
        print(f"   (business type not set: {error})")
    # Without this list OpsAPI shows the owner every module on the platform (F-Gas reports and all).
    s.call("owner", "PUT", "/api/v2/namespace/settings/modules", {"enabled_modules": MODULES})
    # The sidebar has its own per-workspace switches: turn off everything else (plugins keep theirs).
    menu = s.call("owner", "GET", "/api/v2/user/menu")
    keys: set[str] = set()

    def collect(node):
        if isinstance(node, dict):
            if isinstance(node.get("key"), str):
                keys.add(node["key"])
            for value in node.values():
                collect(value)
        elif isinstance(node, list):
            for value in node:
                collect(value)
    collect(menu)
    off = sorted(key for key in keys if key not in MODULES and not key.startswith("plugin:"))
    skipped = []
    for key in off:   # one at a time: the batch call fails outright on a key that isn't a top-level item
        try:
            s.call("owner", "POST", f"/api/v2/namespace/menu-config/{key}/disable", {})
        except APIFailure:
            skipped.append(key)
    if skipped:
        print(f"   (left on, not switchable here: {', '.join(skipped)})")
    # Sales and billing back on (an earlier run switched them off, and switched-off items aren't in
    # the menu read above). The server can answer 500 after it has saved the change, so check the
    # menu afterwards rather than trusting each answer.
    for key in (k for k in SALES if k != "payments"):
        try:
            s.call("owner", "POST", f"/api/v2/namespace/menu-config/{key}/enable", {})
        except APIFailure:
            pass
    shown: set[str] = set()
    keys, menu = shown, s.call("owner", "GET", "/api/v2/user/menu")
    collect(menu)
    missing = [k for k in SALES if k != "payments" and k not in shown]
    if missing:
        die(f"sales menu items still hidden: {', '.join(missing)}")

    print("2b. Property Deals on, set up")
    s.call("owner", "PUT", "/api/v2/namespace/plugins/property_deals", {"enabled": True})
    s.call("owner", "POST", P + "/setup", {}, ok=(200, 201, 409))

    print("3. Manager and operator")
    roles = s.call("owner", "GET", "/api/v2/namespace/roles")
    roles = roles if isinstance(roles, list) else roles.get("roles", [])
    role_id = {r["role_name"]: r["id"] for r in roles}
    # A role update replaces its permissions, so add the back office's to what the plugin gave it.
    back_office = next(r for r in roles if r["role_name"] == BACK_OFFICE_ROLE)
    granted = back_office.get("permissions") or {}
    if isinstance(granted, str):
        granted = json.loads(granted)
    if any(granted.get(module) != actions for module, actions in BACK_OFFICE_GRANTS.items()):
        s.call("owner", "PUT", f"/api/v2/namespace/roles/{back_office['id']}",
               {"permissions": {**granted, **BACK_OFFICE_GRANTS}})
    for key, first, last, username, role in PEOPLE[1:]:
        if not sql_value(f"SELECT 1 FROM users WHERE email = {lit(email(username))}"):
            s.call("owner", "POST", "/api/v2/users",
                   {"email": email(username), "username": username, "password": s.password,
                    "first_name": first, "last_name": last})
        sql(f"UPDATE users SET active = true, updated_at = NOW(), "
            f"password = crypt({lit(s.password)}, gen_salt('bf', 10)) WHERE email = {lit(email(username))}")
        member = sql_value(f"""SELECT m.uuid FROM namespace_members m JOIN users u ON u.id = m.user_id
                               WHERE m.namespace_id = {s.ns_id} AND u.email = {lit(email(username))}""")
        if not member:
            s.call("owner", "POST", "/api/v2/namespace/members",
                   {"email": email(username), "role_ids": [role_id[role]]}, ok=(200, 201))
        else:
            # Creating the user can already add them as a plain member; give them their role.
            s.call("owner", "PUT", f"/api/v2/namespace/members/{member}", {"role_ids": [role_id[role]]})
    for key, _, _, username, _ in PEOPLE:
        row = sql(f"SELECT uuid, id FROM users WHERE username = {lit(username)}")
        if not row:
            die(f"user {username} was not created")
        s.users[key] = {"uuid": row[0][0], "id": int(row[0][1])}


def working_days(s):
    holidays = {h["holiday_date"][:10] for h in s.call("owner", "GET", P + "/holidays?per_page=100")}

    def add(day: datetime.date, n: int) -> datetime.date:
        step = 1 if n > 0 else -1
        while n:
            day += datetime.timedelta(days=step)
            if day.weekday() < 5 and day.isoformat() not in holidays:
                n -= step
        return day
    return add


def iso(moment: datetime.datetime) -> str:
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


def scenario(s) -> None:
    existing = s.call("operator", "GET", P + "/deals?per_page=100")
    if any(d.get("name") == "7 Mill Lane" for d in existing):
        print("4. Scenario already there (7 Mill Lane exists) — leaving it")
        return
    add_wd = working_days(s)
    today = datetime.datetime.now(YORK).date()
    now = datetime.datetime.now(datetime.timezone.utc)

    print("4. 7 Mill Lane: seller lead → deal at Searches")
    prop = s.call("operator", "POST", P + "/properties",
                  {"address_line1": "7 Mill Lane", "town": "York", "postcode": "YO1 7AA", "tenure": "freehold",
                   "lat": 53.9576, "lng": -1.0827})
    lead = s.call("operator", "POST", "/api/v2/crm/leads",
                  {"first_name": "Pat", "last_name": "Probate", "source": "website_form",
                   "email": "pat.probate@example.com", "phone": "07700 900123"})
    deal = s.call("operator", "POST", P + "/deals",
                  {"lead_uuid": lead["uuid"], "property_uuid": prop["uuid"], "deal_type": "buy",
                   "offer_amount": 182500, "agreed_price": 182500,
                   "target_completion_date": add_wd(today, 9).isoformat(),
                   "target_exchange_date": add_wd(today, 7).isoformat(),
                   "late_penalty_per_day": 500, "late_penalty_cap_days": 20})
    d = deal["uuid"]
    tasks = {t["template_key"]: t for t in s.call("operator", "GET", P + f"/tasks?deal_uuid={d}&per_page=100")}
    s.call("operator", "PUT", P + f"/tasks/{tasks['call_back']['task_uuid']}", {"pd_status": "done"})
    s.call("operator", "POST", P + f"/deals/{d}/stage", {"to": "searches"})
    tasks = {t["template_key"]: t for t in s.call("operator", "GET", P + f"/tasks?deal_uuid={d}&per_page=100")}

    print("6. Seller's solicitor: 2 open enquiries, silent for 50 hours")
    for title in ("Missing FENSA certificate for the rear windows", "Boundary responsibility on the east side"):
        s.call("operator", "POST", P + "/enquiries",
               {"deal_uuid": d, "title": title, "owner_party": "seller_solicitor", "blocking": True})
    s.call("operator", "POST", P + "/chases",
           {"deal_uuid": d, "channel": "email", "to_party": "seller_solicitor", "to_name": "Harrow & Co Solicitors",
            "subject": "Enquiries", "status": "replied", "sent_at": iso(now - datetime.timedelta(hours=60)),
            "reply_at": iso(now - datetime.timedelta(hours=50))})

    print("7. The EPC booking is an hour old: overdue, manager told")
    epc = tasks["book_epc"]["task_uuid"]
    sql(f"UPDATE property_deals_task_details SET sla_started_at = NOW() - interval '80 minutes', "
        f"due_at = NOW() - interval '20 minutes' WHERE task_uuid = {lit(epc)}")
    s.call("manager", "POST", P + "/engine/run", {"checks": ["sla"]})
    # The 125% step hands the task to the manager; for the demo the operator keeps it.
    s.call("manager", "PUT", P + f"/tasks/{epc}", {"owner_user_uuid": s.users["operator"]["uuid"]},
           ok=(200, 201, 422))

    print("8. Buyer AML started (so exchange stays blocked)")
    s.call("operator", "POST", P + "/compliance-checks",
           {"check_type": "aml_cdd_buyer", "subject_type": "deal", "deal_uuid": d, "party_role": "buyer",
            "status": "in_progress"})

    print("9. A chase waiting for the operator's approval")
    s.call("manager", "POST", P + "/approvals", {
        "subject_type": "chase", "action": "send_email", "rule": "any_operator", "deal_uuid": d,
        "title": "Chase seller's solicitor — 7 Mill Lane",
        "payload": {
            "to": "conveyancing@harrow-co.example", "subject": "7 Mill Lane: 2 enquiries still open",
            "body": ("Dear Harrow & Co,\n\nWe're still waiting on replies to two enquiries for 7 Mill Lane: the "
                     "missing FENSA certificate for the rear windows, and boundary responsibility on the east "
                     "side. Our last email was two days ago.\n\nExchange is planned in 7 working days. Could you "
                     "reply by 3pm tomorrow?\n\nKind regards,\nSam Okafor\nDemo Buyers Ltd")}})

    print("10. 22 Station Road, a few weeks out")
    prop2 = s.call("operator", "POST", P + "/properties",
                   {"address_line1": "22 Station Road", "town": "York", "postcode": "YO24 1AB", "tenure": "leasehold",
                    "lat": 53.9575, "lng": -1.0932})
    lead2 = s.call("operator", "POST", "/api/v2/crm/leads",
                   {"first_name": "Morgan", "last_name": "Reid", "source": "referral"})
    s.call("operator", "POST", P + "/deals",
           {"lead_uuid": lead2["uuid"], "property_uuid": prop2["uuid"], "deal_type": "buy", "offer_amount": 156000,
            "target_completion_date": add_wd(today, 30).isoformat()})

    s.call("manager", "POST", P + "/engine/run", {"checks": ["health"]}, ok=(200, 201, 422))


SOLICITORS = [
    ("seller_solicitor", "Harrow & Co", "Solicitors", "conveyancing@harrow-co.example", "01904 000111"),
    ("buyer_solicitor", "Pike", "Legal", "property@pike-legal.example", "01904 000222"),
]


def parties(s) -> None:
    """The solicitors on 7 Mill Lane, as CRM contacts (a party is always a contact or an account)."""
    deal = next((d for d in s.call("operator", "GET", P + "/deals?per_page=100") if d.get("name") == "7 Mill Lane"), None)
    if not deal:
        return
    overview = s.call("operator", "GET", P + f"/deals/{deal['uuid']}/overview")
    have = {p.get("role") for p in overview.get("parties") or []}
    print("11. The solicitors on 7 Mill Lane")
    for role, first, last, mail, phone in SOLICITORS:
        if role in have:
            continue
        contact = s.call("operator", "POST", "/api/v2/crm/contacts",
                         {"first_name": first, "last_name": last, "email": mail, "phone": phone})
        contact = contact.get("contact") or contact
        s.call("operator", "POST", P + "/deal-parties",
               {"deal_uuid": deal["uuid"], "role": role, "contact_uuid": contact["uuid"]})


def back_office(s) -> None:
    """A renovation on 22 Station Road with a purchase order, and a hot lead to call (opsapi #709-#711)."""
    deal = next((d for d in s.call("manager", "GET", P + "/deals?per_page=100") if d.get("name") == "22 Station Road"), None)
    if deal:
        renovations = s.call("manager", "GET", P + f"/renovations?status=all&deal_uuid={deal['uuid']}")
        if not renovations:
            print("12. Renovation on 22 Station Road")
            today = datetime.date.today()
            renovations = [s.call("manager", "POST", P + "/renovations",
                                  {"deal_uuid": deal["uuid"], "name": "Renovation — 22 Station Road", "budget": 18000,
                                   "currency": "GBP", "start_date": (today - datetime.timedelta(days=7)).isoformat(),
                                   "target_end_date": (today + datetime.timedelta(days=45)).isoformat()})]
        project = renovations[0].get("project_uuid")
        orders = s.call("manager", "GET", f"/api/v2/purchase-orders?project_uuid={project}") if project else []
        if project and not orders:
            print("13. Purchase order for the kitchen")
            po = s.call("manager", "POST", "/api/v2/purchase-orders",
                        {"supplier_name": "York Kitchens Ltd", "supplier_email": "orders@york-kitchens.example",
                         "reference": "22 Station Road kitchen", "project_uuid": project, "currency": "GBP",
                         "delivery_address": "22 Station Road, York YO24 1AB",
                         "expected_date": (datetime.date.today() + datetime.timedelta(days=5)).isoformat(),
                         "items": [{"description": "Kitchen units (shaker, sage)", "quantity": 1, "unit_price": 3200, "tax_rate": 20},
                                   {"description": "Oak worktop, 3m", "quantity": 3, "unit_price": 180, "tax_rate": 20}]})
            s.call("manager", "POST", f"/api/v2/purchase-orders/{po['uuid']}/send", {})

    if not sql_value(f"SELECT 1 FROM crm_leads WHERE namespace_id = {s.ns_id} AND first_name = 'Pat' "
                     "AND last_name = 'Keen' AND deleted_at IS NULL"):
        print("14. A hot lead: Pat Keen replied")
        lead = s.call("manager", "POST", "/api/v2/crm/leads",
                      {"first_name": "Pat", "last_name": "Keen", "company_name": "Keen Lettings Ltd", "phone": "07700 900123",
                       "email": "pat@keen-lettings.example", "source": "companies_house"})
        lead = lead.get("lead") or lead
        s.call("manager", "PUT", P + f"/leads/{lead['uuid']}/details", {"lead_kind": "seller", "situation": "relocation"})
        s.call("manager", "POST", P + f"/leads/{lead['uuid']}/signals",
               {"kind": "social_post", "text": "Moving to Leeds for work next month. Anyone know a quick way to sell a terrace in York?"})
        s.call("manager", "POST", P + f"/leads/{lead['uuid']}/replies",
               {"channel": "whatsapp",
                "text": "Yes please, can you come round tomorrow? We'd like to sell quickly, ideally before we move."})


def main() -> None:
    password = dbs.seed_password()
    otp = dbs.test_otp()
    s = dbs.Seeder(password, otp)
    people_and_workspace(s)
    scenario(s)
    parties(s)
    back_office(s)

    out = ROOT / "build" / f"{SLUG}.env"
    out.parent.mkdir(exist_ok=True)
    out.write_text("\n".join([
        f"WSL_API={dbs.API}", f"WSL_NAMESPACE={s.ns_uuid}", f"WSL_PASSWORD={password}", f"WSL_OTP={otp}",
        *(f"WSL_USER_{key.upper()}={username}" for key, _, _, username, _ in PEOPLE), ""]))
    out.chmod(0o600)
    print(f"\nDone. Sign-in details in {out.relative_to(ROOT)}")
    for key, first, last, username, role in PEOPLE:
        print(f"  {username:<12} {first} {last} ({role or 'owner'})")


if __name__ == "__main__":
    try:
        main()
    except APIFailure as error:
        die(str(error))
