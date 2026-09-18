#!/usr/bin/env python3
"""Load DBS Ltd's real portfolio into the LOCAL OPSAPI, shaped the way Simpro holds it.

Run after scripts/seed-dbs-limited.py, which builds the workspace, the team and a live working day.
This adds what a Simpro build would already hold for DBS:

  * the customers and sites from DBS's published case studies (dbs.uk.com/projects),
  * maintenance contracts, asset types with their survey readings, and the plant itself,
  * 18 months of condition surveys, F-Gas leak checks and failures, recorded by the engineers,
  * the case studies as project jobs with cost centres, plus three live projects,
  * employee licences, remedial quotes, and a mock Simpro connection with a first pull and push.

Every fact is tagged in scripts/dbs-portfolio.json as published (from DBS's site, their Simpro report
pack or Companies House) or assumed (values the public record does not give). Assumed values are
illustrative only.

Surveys go through POST /api/v2/field-service/assets/:uuid/tests as the engineer who did them, so
the seed exercises the same permission path the app uses on site.

    scripts/seed-dbs-limited.py --reset && scripts/seed-dbs-portfolio.py

Rebuilds the assets, surveys, projects, quotes and sync log on every run; customers, sites, contracts
and asset types are updated in place.
"""
from __future__ import annotations

import hashlib
import importlib.util
import json
import random
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location("dbs_limited", ROOT / "scripts" / "seed-dbs-limited.py")
dbs = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(dbs)

sql, sql_value, lit, die = dbs.sql, dbs.sql_value, dbs.lit, dbs.die
DATA = json.loads((ROOT / "scripts" / "dbs-portfolio.json").read_text())
TODAY = datetime.now(timezone.utc).date()
HISTORY_MONTHS = 18
VAT = 0.20

# Deterministic: the same run produces the same surveys, so screenshots and reports are repeatable.
rng = random.Random(3806201)

# Who surveys what, by asset-type discipline. Keys are the staff keys from seed-dbs-limited.py.
TECHNICIANS = {
    "hvac": ["tom", "kwame", "piotr"],
    "heating": ["sanjay", "piotr"],
    "ventilation": ["piotr", "tom"],
    "controls": ["jake"],
    "electrical": ["jake"],
}

# Job titles and profile details for the team seed-dbs-limited.py creates.
PROFILES = {
    "claire": dict(job_title="Service Manager", code="DBS-004", team="Service & Maintenance", engineer=False),
    "marcus": dict(job_title="Contracts Manager", code="DBS-007", team="Projects", engineer=False),
    "aisha": dict(job_title="Service Co-ordinator", code="DBS-012", team="Service & Maintenance", engineer=False),
    "tom": dict(job_title="Senior AC & Refrigeration Engineer", code="DBS-021", team="Service & Maintenance",
                engineer=True, rate=34, bill=85, licences=["engineer"]),
    "kwame": dict(job_title="Refrigeration Engineer", code="DBS-023", team="Service & Maintenance",
                  engineer=True, rate=31, bill=85, licences=["engineer"]),
    "jake": dict(job_title="Electrical & Controls Engineer", code="DBS-031", team="Electrical",
                 engineer=True, rate=32, bill=82, licences=["electrical"]),
    "ryan": dict(job_title="Apprentice Engineer", code="DBS-044", team="Projects", engineer=True, rate=14,
                 bill=45, apprentice=True, licences=["engineer"]),
    "piotr": dict(job_title="PPM & F-Gas Engineer", code="DBS-026", team="Service & Maintenance",
                  engineer=True, rate=30, bill=78, licences=["engineer", "gas"]),
    "sanjay": dict(job_title="AC & Heat Pump Engineer", code="DBS-028", team="Service & Maintenance",
                   engineer=True, rate=32, bill=82, licences=["engineer", "gas"]),
}


def add_months(d: date, n: int) -> date:
    month = d.month - 1 + n
    year = d.year + month // 12
    month = month % 12 + 1
    days = [31, 29 if year % 4 == 0 and (year % 100 or year % 400 == 0) else 28, 31, 30, 31, 30, 31, 31, 30, 31,
            30, 31][month - 1]
    return date(year, month, min(d.day, days))


def jdump(value) -> str:
    return lit(json.dumps(value)) + "::jsonb"


def serial_for(tag: str) -> str:
    # Synthetic, stable serial numbers — real ones are not public.
    return "SN" + hashlib.sha1(tag.encode()).hexdigest()[:10].upper()


# ---------------------------------------------------------------------------------------------
# Workspace and team
# ---------------------------------------------------------------------------------------------

def brand_workspace(s) -> None:
    company = DATA["company"]
    settings = sql_value(f"SELECT COALESCE(settings, '{{}}') FROM namespaces WHERE id = {s.ns_id}") or "{}"
    try:
        merged = json.loads(settings)
    except ValueError:
        merged = {}
    merged["company"] = {k: company[k] for k in (
        "display_name", "legal_name", "company_number", "vat_number", "address", "phone", "email", "strapline")}
    # The workspace keeps the name the seed was asked for (NAMESPACE_NAME); only
    # the letterhead details below come from the portfolio's company block.
    sql(f"""UPDATE namespaces SET name = {lit(dbs.NAMESPACE['name'])},
            description = {lit('HVAC, refrigeration, heating, electrical and controls — service, maintenance and projects')},
            logo_url = '/brands/dbs-ltd.svg', settings = {lit(json.dumps(merged))}, updated_at = NOW()
            WHERE id = {s.ns_id}""")


def team_profiles(s) -> dict[str, str]:
    employees = {}
    for key, p in PROFILES.items():
        user_uuid = s.users[key]["uuid"]
        uuid = sql_value(f"SELECT uuid FROM employees WHERE namespace_id = {s.ns_id} "
                         f"AND user_uuid = {lit(user_uuid)} AND deleted_at IS NULL")
        if not uuid:
            uuid = s.call("owner", "POST", "/api/v2/field-service/employees", {
                "user_uuid": user_uuid, "is_engineer": p["engineer"], "job_title": p["job_title"],
                "employee_code": p["code"], "hourly_cost_rate": p.get("rate"),
            })["uuid"]
        started = add_months(TODAY, -rng.randint(14, 150)) if not p.get("apprentice") else add_months(TODAY, -11)
        fgas = f"FGAS-{p['code'][-3:]}{rng.randint(1000, 9999)}" if "engineer" in p.get("licences", []) else None
        sql(f"""UPDATE employees SET job_title = {lit(p['job_title'])}, employee_code = {lit(p['code'])},
                is_engineer = {str(p['engineer']).lower()}, is_active = true, team = {lit(p['team'])},
                date_started = {lit(started.isoformat())}, is_apprentice = {str(bool(p.get('apprentice'))).lower()},
                staff_type = {lit('apprentice' if p.get('apprentice') else ('employee' if p['engineer'] else 'office'))},
                hourly_cost_rate = {p.get('rate') or 'NULL'}, bill_rate = {p.get('bill') or 'NULL'},
                fgas_certificate_no = {lit(fgas) if fgas else 'NULL'}, region = 'London & South East'
                WHERE uuid = {lit(uuid)}""")
        employees[key] = uuid
    return employees


def licences(s, employees: dict[str, str]) -> int:
    sql(f"DELETE FROM employee_licences WHERE namespace_id = {s.ns_id}")
    by_role = DATA["licences"]["by_role"]
    # A few licences are deliberately about to lapse, and one has, so the report has something to flag.
    lapsing = {("tom", "F-Gas Category I (City & Guilds 2079)"): 23,
               ("kwame", "CSCS — Skilled Worker"): 41,
               ("sanjay", "Gas Safe — ACS CCN1, COCN1, CDGA1"): 67,
               ("ryan", "IPAF 3a/3b"): -12,
               ("claire", "First Aid at Work"): 55}
    count = 0
    for key, p in PROFILES.items():
        groups = list(p.get("licences", [])) + (["manager"] if not p["engineer"] and key != "aisha" else [])
        for group in groups:
            for licence_type, body, months in by_role[group]:
                if licence_type.startswith("NVQ") and p.get("apprentice"):
                    licence_type = "NVQ Level 2 — Refrigeration & Air Conditioning (in training)"
                days_left = lapsing.get((key, licence_type))
                if months is None:
                    issued, expires = add_months(TODAY, -rng.randint(24, 120)), None
                elif days_left is not None:
                    expires = TODAY + timedelta(days=days_left)
                    issued = add_months(expires, -months)
                else:
                    issued = add_months(TODAY, -rng.randint(3, months - 4))
                    expires = add_months(issued, months)
                s.call("owner", "POST", f"/api/v2/field-service/employees/{employees[key]}/licences", {
                    "licence_type": licence_type, "issuing_body": body,
                    "licence_number": f"{body[:3].upper()}-{rng.randint(100000, 999999)}",
                    "issued_on": issued.isoformat(), "expires_on": expires.isoformat() if expires else None,
                })
                count += 1
    return count


# ---------------------------------------------------------------------------------------------
# CRM: customers, contacts, sites, contracts
# ---------------------------------------------------------------------------------------------

def customers(s) -> dict[str, str]:
    out = {}
    for c in DATA["customers"]:
        email = f"facilities@{c['key']}.dbs-demo.example"
        uuid = sql_value(f"SELECT uuid FROM customers WHERE namespace_id = {s.ns_id} AND email = {lit(email)}")
        if not uuid:
            uuid = s.call("claire", "POST", "/api/v2/customers", {
                "first_name": c["company_name"], "email": email,
                "notes": f"{c['group']}. Case study: {c['source']}",
            })["uuid"]
        custom = {"source": c["source"], "data_basis": "published name; contacts and terms assumed"}
        if c.get("note"):
            custom["note"] = c["note"]
        sql(f"""UPDATE customers SET company_name = {lit(c['company_name'])}, first_name = {lit(c['company_name'])},
                last_name = NULL, customer_type = 'company', customer_group = {lit(c['group'])},
                payment_terms_days = {c['terms']}, requires_order_no = {str(bool(c.get('requires_order_no'))).lower()},
                account_manager_uuid = {lit(s.users['claire']['uuid'])}, custom_fields = {jdump(custom)},
                created_at = NOW() - interval '4 years'
                WHERE uuid = {lit(uuid)}""")
        # A role-based contact per customer: who receives the PPM reports and invoices.
        sql(f"""DELETE FROM fs_contacts WHERE customer_id = (SELECT id FROM customers WHERE uuid = {lit(uuid)});
                INSERT INTO fs_contacts (uuid, namespace_id, customer_id, position, email, is_primary, notes)
                SELECT gen_random_uuid()::text, {s.ns_id}, id, 'Facilities Manager', {lit(email)}, true,
                       'Receives PPM reports, remedial quotations and invoices.'
                FROM customers WHERE uuid = {lit(uuid)}""")
        out[c["key"]] = uuid
    return out


def day_story_customers(s) -> None:
    """Give the day-in-the-life customers from seed-dbs-limited.py their Simpro shape.

    They were created before customers had company_name / customer_type, so the company name sits
    in first_name. Restated from the source dict on every run, which also repairs any row a sync
    has touched.
    """
    for c in dbs.CUSTOMERS.values():
        individual = bool(c.get("last_name"))
        sql(f"""UPDATE customers SET first_name = {lit(c['first_name'])},
                last_name = {lit(c['last_name']) if individual else 'NULL'},
                company_name = {'NULL' if individual else lit(c['first_name'])},
                customer_type = {lit('individual' if individual else 'company')}
                WHERE namespace_id = {s.ns_id} AND email = {lit(c['email'])}""")


def sites(s, customer_uuids: dict[str, str]) -> dict[str, str]:
    out = {}
    for site in DATA["sites"]:
        fields = {"customer_uuid": customer_uuids[site["customer"]], "name": site["name"],
                  "address_line1": site["line1"], "city": site["city"], "county": site.get("county"),
                  "postal_code": site["postcode"], "country": "United Kingdom",
                  "access_notes": site.get("note")}
        uuid = sql_value(f"""SELECT s.uuid FROM fs_sites s JOIN customers c ON c.id = s.customer_id
                             WHERE s.namespace_id = {s.ns_id} AND c.uuid = {lit(customer_uuids[site['customer']])}
                             AND s.name = {lit(site['name'])} AND s.deleted_at IS NULL""")
        if uuid:
            s.call("claire", "PUT", f"/api/v2/field-service/sites/{uuid}", fields)
        else:
            uuid = s.call("claire", "POST", "/api/v2/field-service/sites", fields)["uuid"]
        precision = "district" if site["postcode"] and len(site["postcode"]) <= 4 else "unknown"
        sql(f"""UPDATE fs_sites SET zone = {lit(site['zone'])}, site_type = {lit(site['type'])},
                latitude = {site['lat']}, longitude = {site['lng']},
                custom_fields = {jdump({'address_precision': precision,
                                        'note': 'Location from the case study; street address not published.'})},
                created_at = NOW() - interval '3 years'
                WHERE uuid = {lit(uuid)}::uuid""")
        out[site["key"]] = uuid

    # The day-in-the-life sites from seed-dbs-limited.py get coordinates too, so the engineer map
    # and zone reports cover the whole workspace.
    zones = {"Greater London": "London South", "Surrey": "Surrey", "Berkshire": "Berkshire"}
    for key, t in dbs.SITES.items():
        _, name, line1, city, county, postcode, *_rest, lat, lng = t
        sql(f"""UPDATE fs_sites SET latitude = {lat}, longitude = {lng},
                zone = COALESCE(zone, {lit(zones.get(county, 'London South'))})
                WHERE namespace_id = {s.ns_id} AND address_line1 = {lit(line1)}""")
    return out


def contracts(s, customer_uuids: dict[str, str]) -> dict[str, str]:
    out = {}
    for c in DATA["contracts"]:
        manager = s.users[c["manager"]]["uuid"]
        body = {"customer_uuid": customer_uuids[c["customer"]], "contract_number": c["number"], "name": c["name"],
                "start_date": c["start"], "end_date": c["end"], "extension_months": c.get("extension_months"),
                "annual_value": c["annual_value"], "response_hours": c["response_hours"],
                "resolve_hours": c["resolve_hours"], "quote_turnaround_hours": c["quote_hours"],
                "covers_out_of_hours": bool(c.get("out_of_hours")), "service_manager_uuid": manager,
                "coordinator_uuid": s.users["aisha"]["uuid"], "status": "active",
                "description": c.get("published") or c.get("assumed"),
                "custom_fields": {"published": c.get("published"), "assumed": c.get("assumed")}}
        uuid = sql_value(f"SELECT uuid FROM fs_contracts WHERE namespace_id = {s.ns_id} "
                         f"AND contract_number = {lit(c['number'])} AND deleted_at IS NULL")
        if uuid:
            s.call("marcus", "PUT", f"/api/v2/field-service/contracts/{uuid}", body)
        else:
            uuid = s.call("marcus", "POST", "/api/v2/field-service/contracts", body)["uuid"]
        out[c["key"]] = uuid
    return out


def asset_types(s) -> dict[str, dict]:
    defs = DATA["readings"]
    out = {}
    existing = {t["name"]: t["uuid"] for t in
                s.call("marcus", "GET", "/api/v2/field-service/asset-types?include_inactive=true")}
    for t in DATA["asset_types"]:
        body = {"name": t["name"], "code": t["code"], "discipline": t["discipline"], "is_fgas": t["fgas"],
                "default_service_months": t["months"],
                "readings": [{"key": k, **defs[k]} for k in t["readings"]],
                "failure_points": [{"key": f.lower().replace(" ", "_").replace("/", ""), "label": f}
                                   for f in t["failures"]],
                "consumables": t["consumables"],
                "description": f"Survey definition for {t['name'].lower()} (Simpro asset type {t['code']})."}
        if t["name"] in existing:
            uuid = existing[t["name"]]
            s.call("marcus", "PUT", f"/api/v2/field-service/asset-types/{uuid}", body)
        else:
            uuid = s.call("marcus", "POST", "/api/v2/field-service/asset-types", body)["uuid"]
        out[t["name"]] = {"uuid": uuid, **t}
    return out


# ---------------------------------------------------------------------------------------------
# Assets and their survey history
# ---------------------------------------------------------------------------------------------

def asset_plan() -> list[dict]:
    """The published plant, plus the children and samples it implies."""
    plan = []
    for a in DATA["assets"]:
        plan.append(dict(a))
        for i in range(1, a.get("fcus", 0) + 1):
            plan.append({"tag": f"{a['tag']}-FCU{i:02d}", "site": a["site"], "type": "Fan coil / indoor unit",
                         "name": f"Daikin ducted FCU {i} on VRV {a['name'].split()[-1]}", "manufacturer": "Daikin",
                         "model": "Ducted FCU", "installed": a["installed"], "contract": a.get("contract"),
                         "parent": a["tag"], "condition": rng.choice([1, 2, 2, 2, 3]), "basis": "published count"})
    sample = DATA["skanska_sample"]
    n = 0
    for site in sample["boilers"]["sites"]:
        for i in range(1, sample["boilers"]["per_site"] + 1):
            n += 1
            age = rng.randint(4, 22)
            plan.append({"tag": f"COL-BLR-{n:03d}", "site": site, "type": "Gas boiler",
                         "name": f"Heating boiler {i} — {site.split('_')[1]} zone", "installed":
                         add_months(TODAY, -age * 12).isoformat(), "contract": sample["boilers"]["contract"],
                         "condition": min(6, max(1, age // 4 + rng.choice([0, 0, 1]))),
                         "basis": "sample of the published 100+ boilers; attributes assumed"})
    n = 0
    for site in sample["chillers"]["sites"]:
        for i in range(1, sample["chillers"]["per_site"] + 1):
            n += 1
            age = rng.randint(6, 18)
            plan.append({"tag": f"COL-CHL-{n:03d}", "site": site, "type": "Air-cooled chiller",
                         "name": f"Chiller {i} — {site.split('_')[1]} zone",
                         "refrigerant": sample["chillers"]["refrigerant"],
                         "charge": sample["chillers"]["charge"][(i - 1) % 3],
                         "installed": add_months(TODAY, -age * 12).isoformat(),
                         "contract": sample["chillers"]["contract"],
                         "condition": min(6, max(1, age // 3 - 1 + rng.choice([0, 1]))),
                         "basis": "sample of the published 40 chillers; attributes assumed"})
    return plan


def reading_value(key: str, condition: int, fail: bool):
    drift = (condition - 1) / 5  # 0 healthy .. 1 worn out
    ranges = {
        "suction_bar": (8.5, 1.5), "discharge_bar": (27.0, 5.0), "compressor_amps": (14.0, 6.0),
        "ambient_c": (16.0, 0.0), "supply_air_c": (13.0, 4.0), "return_air_c": (22.5, 0.0),
        "flow_c": (48.0, -6.0), "return_c": (40.0, -3.0), "co_ppm": (40.0, 90.0), "co2_pct": (9.2, -0.8),
        "gas_mbar": (19.5, -1.5), "leaving_water_c": (7.0, 3.0), "entering_water_c": (12.0, 2.0),
        "airflow_ls": (420.0, -120.0), "motor_amps": (2.4, 1.2), "open_time_s": (24.0, 30.0),
        "points_checked": (64.0, 0.0), "alarms_active": (0.0, 4.0), "ir_mohm": (250.0, -200.0),
        "zs_ohm": (0.35, 0.4), "rcd_ms": (22.0, 18.0),
    }
    if key in ranges:
        base, span = ranges[key]
        value = base + span * drift + rng.uniform(-0.06, 0.06) * abs(base or 1)
        if fail and key in ("co_ppm", "rcd_ms", "open_time_s", "alarms_active"):
            value += abs(span) * 0.8
        return round(value, 2 if abs(base) < 10 else 1)
    if key == "filter":
        return rng.choice(["Clean", "Cleaned", "Replaced"] if condition < 4 else ["Replaced", "Replaced", "Cleaned"])
    if key == "defrost":
        return "Fault" if fail else "OK"
    if key == "battery_ok":
        return "Replace" if fail else "OK"
    if key == "leak_check":
        return "Fail" if fail else "Pass"
    return None


def survey_history(s, assets: list[dict], types: dict[str, dict], contract_uuids: dict[str, str]) -> dict:
    stats = {"tests": 0, "fails": 0, "advisories": 0, "overdue_levels": 0}
    display = {k: sql_value(f"SELECT TRIM(first_name || ' ' || last_name) FROM users WHERE uuid = {lit(v['uuid'])}")
               for k, v in s.users.items()}

    for a in assets:
        t = types[a["type"]]
        target = int(a["condition"])
        detail = s.call("marcus", "GET", f"/api/v2/field-service/assets/{a['uuid']}")
        levels = detail.get("service_levels") or []
        contract = contract_uuids.get(a.get("contract")) if a.get("contract") else None

        # Name the auto-created schedule after the contract regime, and add the statutory leak check
        # where the refrigerant charge requires one.
        plans = []
        installed = date.fromisoformat(a["installed"])
        start = max(installed, add_months(TODAY, -HISTORY_MONTHS))
        freq = t["months"]
        label = {3: "Quarterly PPM (SFG20)", 6: "Six-monthly PPM (SFG20)", 12: "Annual service"}.get(freq, "PPM")
        if levels:
            level = levels[0]
            s.call("marcus", "PUT", f"/api/v2/field-service/service-levels/{level['uuid']}", {
                "name": label, "contract_uuid": contract, "estimated_hours": {3: 1.5, 6: 2.5, 12: 3.0}[freq],
                "next_service_date": add_months(start, freq).isoformat(), "last_service_date": None})
            plans.append((level["uuid"], freq, "service"))
        if detail.get("leak_check_months"):
            months = int(detail["leak_check_months"])
            level = s.call("marcus", "POST", f"/api/v2/field-service/assets/{a['uuid']}/service-levels", {
                "name": "F-Gas leak check", "kind": "fgas_leak_check", "frequency_months": months,
                "contract_uuid": contract, "estimated_hours": 1.0,
                "next_service_date": add_months(start, months).isoformat()})
            plans.append((level["uuid"], months, "fgas"))

        # Walk each schedule forward, recording the survey the engineer did against each due date.
        worn = target >= 4
        skip_last = worn and rng.random() < 0.6 or rng.random() < 0.06
        for level_uuid, months, kind in plans:
            due = add_months(start, months)
            dues = []
            while due <= TODAY:
                dues.append(due)
                due = add_months(due, months)
            if skip_last and dues and kind == "service":
                dues = dues[:-1]
                stats["overdue_levels"] += 1
            for i, due in enumerate(dues):
                progress = (i + 1) / max(len(dues), 1)
                condition = max(1, min(6, round(1 + (target - 1) * progress + rng.choice([-0.4, 0, 0, 0.4]))))
                fail = (condition >= 5 and rng.random() < 0.45) or (condition == 4 and rng.random() < 0.18) \
                    or rng.random() < 0.03
                advisory = not fail and condition >= 3 and rng.random() < 0.3
                # Most surveys land in the month they were due; some slip into the next.
                if rng.random() < 0.13:
                    tested = add_months(due, 1).replace(day=min(rng.randint(2, 20), 28))
                else:
                    tested = due.replace(day=min(max(1, due.day + rng.randint(-6, 6)), 28))
                tested = min(tested, TODAY)
                # A survey dated today happened this morning, not later today.
                at = (datetime.now(timezone.utc) - timedelta(hours=2)).strftime("%H:%M:00") \
                    if tested == TODAY else "10:30:00"
                technician = rng.choice(TECHNICIANS[t["discipline"]])
                readings = [{"key": k, "label": DATA["readings"][k]["label"],
                             "value": condition if k == "condition" else
                             (max(1, min(6, condition + rng.choice([-1, 0, 0]))) if k == "operational"
                              else reading_value(k, condition, fail)),
                             "unit": DATA["readings"][k].get("unit")}
                            for k in t["readings"] if kind == "service" or k in ("condition", "leak_check")]
                failure_points = []
                added = recovered = None
                leak = None
                if t["fgas"]:
                    leak = "fail" if fail and kind == "fgas" else "pass"
                if fail:
                    point = rng.choice(t["failures"])
                    if kind == "fgas":
                        point = "Refrigerant leak"
                    failure_points = [{"key": point.lower().replace(" ", "_"), "label": point,
                                       "severity": "high" if condition >= 5 else "medium"}]
                    if point in ("Refrigerant leak", "Low charge") and a.get("charge"):
                        added = round(a["charge"] * rng.uniform(0.04, 0.12), 2)
                        leak = "fail"
                result = "fail" if fail else ("advisory" if advisory else "pass")
                s.call(technician, "POST", f"/api/v2/field-service/assets/{a['uuid']}/tests", {
                    "service_level_uuid": level_uuid, "tested_at": f"{tested.isoformat()} {at}",
                    "technician_name": display[technician], "result": result, "condition_rating": condition,
                    "readings": readings, "failure_points": failure_points,
                    "refrigerant_type": a.get("refrigerant"), "refrigerant_added_kg": added,
                    "refrigerant_recovered_kg": recovered,
                    "leak_check_result": leak if kind == "fgas" or added else None,
                    "condition_notes": a.get("condition_notes") if i == len(dues) - 1 else None,
                    "notes": {"pass": "Serviced to SFG20; no defects.",
                              "advisory": "Serviced; wear noted for the next visit.",
                              "fail": f"{failure_points[0]['label'] if failure_points else 'Defect'} found; "
                                      "made safe and reported."}[result],
                    "recommendation": ("Remedial quotation raised." if fail else
                                       "Budget for replacement." if condition >= 5 else None),
                })
                stats["tests"] += 1
                stats["fails"] += result == "fail"
                stats["advisories"] += result == "advisory"
    return stats


def assets(s, site_uuids, type_defs, contract_uuids) -> list[dict]:
    # Rebuilt each run so the survey history never doubles up.
    sql(f"DELETE FROM fs_assets WHERE namespace_id = {s.ns_id}")
    plan = asset_plan()
    by_tag = {}
    for a in plan:
        body = {"site_uuid": site_uuids[a["site"]], "asset_type_uuid": type_defs[a["type"]]["uuid"],
                "contract_uuid": contract_uuids.get(a.get("contract")) if a.get("contract") else None,
                "parent_uuid": by_tag[a["parent"]]["uuid"] if a.get("parent") else None,
                "asset_tag": a["tag"], "name": a["name"], "manufacturer": a.get("manufacturer"),
                "model": a.get("model"), "serial_number": serial_for(a["tag"]),
                "location_detail": a.get("location"), "installed_at": a["installed"],
                "warranty_expires_at": add_months(date.fromisoformat(a["installed"]), 60).isoformat(),
                "refrigerant_type": a.get("refrigerant"), "refrigerant_charge_kg": a.get("charge"),
                "custom_fields": {"data_basis": a.get("basis", "assumed")}}
        created = s.call("marcus", "POST", "/api/v2/field-service/assets", body)
        a["uuid"] = created["uuid"]
        by_tag[a["tag"]] = a
    sql(f"UPDATE fs_assets SET created_at = installed_at::timestamp WHERE namespace_id = {s.ns_id}")
    return plan


# ---------------------------------------------------------------------------------------------
# Projects (Simpro project jobs with cost centres)
# ---------------------------------------------------------------------------------------------

def project_job_type(s) -> str:
    existing = {t["name"]: t["uuid"] for t in
                s.call("marcus", "GET", "/api/v2/field-service/job-types?include_inactive=true")}
    name = "M&E project"
    if name in existing:
        return existing[name]
    uuid = s.call("marcus", "POST", "/api/v2/field-service/job-types", {
        "name": name, "description": "Design & build / fit-out project, billed by cost centre",
        "default_hourly_rate": 72, "color": "#0f766e"})["uuid"]
    for phase, hours, signoff, checklist in [
        ("Design & co-ordination", 40, False, ["Survey and design", "RAMS issued", "Drawings approved"]),
        ("Installation", 320, False, ["First fix", "Second fix", "Pressure testing"]),
        ("Commissioning & handover", 40, True, ["Witness testing", "O&M manuals", "Client sign-off"]),
    ]:
        s.call("marcus", "POST", f"/api/v2/field-service/job-types/{uuid}/phases",
               {"name": phase, "requires_visit": False, "requires_signoff": signoff,
                "estimated_hours": hours, "checklist": checklist})
    return uuid


def remove_portfolio_jobs(s) -> None:
    ids = f"SELECT id FROM fs_jobs WHERE namespace_id = {s.ns_id} AND metadata->>'source' = 'dbs-portfolio'"
    sql(f"""BEGIN;
        DELETE FROM fs_job_cost_centres WHERE job_id IN ({ids});
        DELETE FROM fs_job_sections WHERE job_id IN ({ids});
        DELETE FROM fs_job_activity WHERE job_id IN ({ids});
        DELETE FROM fs_job_items WHERE job_id IN ({ids});
        DELETE FROM fs_visits WHERE job_id IN ({ids});
        DELETE FROM fs_job_phases WHERE job_id IN ({ids});
        DELETE FROM fs_jobs WHERE id IN ({ids});
        COMMIT;""")


def projects(s, customer_uuids, site_uuids) -> dict:
    remove_portfolio_jobs(s)
    job_type = project_job_type(s)
    totals = {"projects": 0, "value": 0.0}

    def create(p, number, stage, status, issued: date, started: date, finished: date | None, due: date,
               claimed_share: float, source: dict):
        job = s.call("marcus", "POST", "/api/v2/field-service/jobs", {
            "title": p["title"], "description": p["summary"], "priority": "normal", "job_type_uuid": job_type,
            "customer_uuid": customer_uuids[p["customer"]], "service_manager_uuid": s.users["marcus"]["uuid"],
            "due_date": due.isoformat()})
        s.call("marcus", "PUT", f"/api/v2/field-service/jobs/{job['uuid']}",
               {"site_uuid": site_uuids[p["site"]], "customer_reference": f"PO-{rng.randint(410000, 489999)}"})
        value = float(p["value"])
        margin = rng.uniform(0.22, 0.31)
        job_id = sql_value(f"SELECT id FROM fs_jobs WHERE uuid = {lit(job['uuid'])}")
        sql(f"""UPDATE fs_jobs SET job_number = {lit(number)}, kind = 'project', stage = {lit(stage)},
                status = {lit(status)}, date_issued = {lit(issued.isoformat())},
                started_at = {lit(started.isoformat())}::timestamp,
                completed_at = {lit(finished.isoformat()) + '::timestamp' if finished else 'NULL'},
                due_date = {lit(due.isoformat())}, total_ex_tax = {value:.2f}, total_inc_tax = {value * (1 + VAT):.2f},
                order_no = customer_reference, project_manager_uuid = {lit(s.users['marcus']['uuid'])},
                salesperson_uuid = {lit(s.users['owner']['uuid'])},
                zone = (SELECT zone FROM fs_sites WHERE id = site_id),
                estimated_hours = {round(value * (1 - margin) * 0.38 / 34)},
                metadata = {jdump({'source': 'dbs-portfolio', **source})},
                created_at = {lit(issued.isoformat())}::timestamp, updated_at = NOW()
                WHERE id = {job_id};
            UPDATE fs_job_phases SET status = {lit('completed' if finished else 'in_progress')},
                completed_at = {lit(finished.isoformat()) + '::timestamp' if finished else 'NULL'}
                WHERE job_id = {job_id} {"" if finished else "AND sort_order = 1"};""")

        section_ids = []
        for i, name in enumerate(p.get("sections", [])):
            section_ids.append(sql_value(f"""INSERT INTO fs_job_sections (uuid, namespace_id, job_id, name, display_order)
                VALUES (gen_random_uuid()::text, {s.ns_id}, {job_id}, {lit(name)}, {i}) RETURNING id"""))
        for i, (name, discipline, share) in enumerate(p["cost_centres"]):
            total = value * share
            cost = total * (1 - margin)
            done = 1.0 if finished else claimed_share
            section = section_ids[i % len(section_ids)] if section_ids else "NULL"
            cc_stage = "complete" if finished else ("progress" if claimed_share > 0 else "pending")
            sql(f"""INSERT INTO fs_job_cost_centres (uuid, namespace_id, job_id, section_id, name, code, discipline,
                    stage, estimated_hours, actual_hours, estimated_cost, actual_cost, total_ex_tax, total_inc_tax,
                    claimed_ex_tax, display_order, simpro_sync_state)
                VALUES (gen_random_uuid()::text, {s.ns_id}, {job_id}, {section}, {lit(name)},
                    {lit(f'CC-{i + 1:02d}')}, {lit(discipline)}, {lit(cc_stage)},
                    {cost * 0.38 / 34:.2f}, {cost * 0.38 / 34 * done * rng.uniform(0.92, 1.08):.2f},
                    {cost:.2f}, {cost * done * rng.uniform(0.95, 1.06):.2f}, {total:.2f}, {total * (1 + VAT):.2f},
                    {total * done:.2f}, {i}, 'synced')""")
        totals["projects"] += 1
        totals["value"] += value

    for i, p in enumerate(sorted(DATA["projects"], key=lambda x: x["completed"]), start=1):
        finished = date.fromisoformat(p["completed"])
        weeks = p.get("weeks") or max(3, min(40, p["value"] / 18000))
        started = finished - timedelta(weeks=weeks)
        create(p, f"PRJ-{finished.year}-{i:03d}", "complete", "completed", started - timedelta(days=21), started,
               finished, finished, 1.0, {"case_study": f"https://dbs.uk.com/project/{p['slug']}",
                                         "value_basis": "Illustrative estimate — DBS case studies do not publish values",
                                         "dates_basis": "Completion approximated from the case study's publication date"})
    for j, p in enumerate(DATA["live_projects"], start=1):
        started = TODAY + timedelta(days=p["start_offset_days"])
        due = TODAY + timedelta(days=p["due_offset_days"])
        issued = min(started, TODAY) - timedelta(days=14)
        create(p, f"PRJ-{TODAY.year}-L{j:02d}", p["stage"], "in_progress" if p["stage"] == "progress" else "scheduled",
               issued, started, None, due, p["claimed"], {"value_basis": "Demo assumption"})
    return totals


# ---------------------------------------------------------------------------------------------
# Quotes, Simpro sync
# ---------------------------------------------------------------------------------------------

def quotes(s) -> int:
    sql(f"DELETE FROM fs_quotes WHERE namespace_id = {s.ns_id}")
    n = 0
    # Remedial quotes raised from the latest failed survey on each asset.
    rows = sql(f"""SELECT DISTINCT ON (a.id) a.id, a.site_id, a.customer_id, a.asset_tag, a.name, th.tested_at,
                          th.failure_points->0->>'label'
                   FROM fs_asset_test_history th JOIN fs_assets a ON a.id = th.asset_id
                   WHERE th.namespace_id = {s.ns_id} AND th.result = 'fail'
                   ORDER BY a.id, th.tested_at DESC""")
    for asset_id, site_id, customer_id, tag, name, tested_at, failure in rows:
        n += 1
        turnaround = rng.choice([6, 18, 26, 31, 40, 44, 52, 70])
        value = rng.choice([380, 640, 920, 1450, 2250, 3800])
        stage, status = rng.choice([("approved", "accepted"), ("complete", "sent"), ("archived", "declined"),
                                    ("complete", "sent")])
        sql(f"""INSERT INTO fs_quotes (uuid, namespace_id, quote_number, customer_id, site_id, asset_id, title,
                    description, stage, status, salesperson_uuid, date_issued, valid_until, sent_at, decided_at,
                    subtotal, tax_amount, total_amount, created_by_uuid, created_at, updated_at, simpro_sync_state)
                VALUES (gen_random_uuid()::text, {s.ns_id}, {lit(f'QUO-{3100 + n}')}, {customer_id}, {site_id},
                    {asset_id}, {lit(f'Remedial works — {tag}: {failure or "defect"}')},
                    {lit(f'Raised from the survey of {name}.')}, {lit(stage)}, {lit(status)},
                    {lit(s.users['claire']['uuid'])}, ({lit(str(tested_at))}::timestamp + interval '1 day')::date,
                    ({lit(str(tested_at))}::timestamp + interval '31 days')::date,
                    {lit(str(tested_at))}::timestamp + interval '{turnaround + 20} hours',
                    CASE WHEN {lit(status)} IN ('accepted', 'declined')
                         THEN {lit(str(tested_at))}::timestamp + interval '9 days' END,
                    {value}, {value * VAT}, {value * (1 + VAT)}, {lit(s.users['claire']['uuid'])},
                    {lit(str(tested_at))}::timestamp + interval '20 hours', NOW(), 'synced')""")
    # The service desk's quotes against today's requests, for the turnaround report.
    for rid, customer_id, created in sql(f"""SELECT id, customer_id, created_at FROM fs_service_requests
                                              WHERE namespace_id = {s.ns_id} ORDER BY created_at LIMIT 8"""):
        n += 1
        hours = rng.choice([4, 11, 20, 29, 47, 58])
        sql(f"""INSERT INTO fs_quotes (uuid, namespace_id, quote_number, customer_id, service_request_id, title, stage,
                    status, date_issued, sent_at, subtotal, tax_amount, total_amount, created_at, updated_at)
                SELECT gen_random_uuid()::text, {s.ns_id}, {lit(f'QUO-{3100 + n}')}, {customer_id or 'NULL'}, {rid},
                    'Remedial works quotation', 'complete', 'sent', {lit(str(created))}::date,
                    LEAST(NOW(), {lit(str(created))}::timestamp + interval '{hours + 2} hours'),
                    480, 96, 576, {lit(str(created))}::timestamp + interval '2 hours', NOW()""")
    return n


def simpro(s) -> dict:
    ns = s.ns_id
    sql(f"DELETE FROM simpro_sync_log WHERE namespace_id = {ns}")
    s.call("owner", "PUT", "/api/v2/field-service/simpro/connection", {
        "name": "DBS Ltd Simpro", "mode": "mock", "base_url": "mock://dbs.simprosuite.com", "company_id": "0",
        "pull_enabled": True, "push_enabled": True, "sync_interval_minutes": 15})

    # What the demo pretends has already been through Simpro: the portfolio customers, their sites, the
    # plant and the projects. The day-in-the-life customers and the Verulam FCUs stay local, so the first
    # push has real work to do.
    stamp = "simpro_synced_at = NOW() - interval '20 minutes', simpro_sync_state = 'synced'"
    sql(f"""
        UPDATE customers SET simpro_id = (10000 + id)::text, updated_at = NOW() - interval '1 hour', {stamp}
            WHERE namespace_id = {ns} AND email LIKE '%.dbs-demo.example';
        UPDATE fs_sites s SET simpro_id = (20000 + s.id)::text, updated_at = NOW() - interval '1 hour', {stamp}
            FROM customers c WHERE c.id = s.customer_id AND c.simpro_id IS NOT NULL AND s.namespace_id = {ns};
        UPDATE fs_asset_types SET simpro_id = (30000 + id)::text, {stamp} WHERE namespace_id = {ns};
        UPDATE fs_assets SET simpro_id = (40000 + id)::text, updated_at = NOW() - interval '1 hour', {stamp}
            WHERE namespace_id = {ns} AND asset_tag NOT LIKE 'VER-VRV-%-FCU%';
        UPDATE fs_assets SET simpro_id = NULL, simpro_sync_state = 'pending'
            WHERE namespace_id = {ns} AND asset_tag LIKE 'VER-VRV-%-FCU%';
        UPDATE fs_contracts SET simpro_id = (60000 + id)::text, {stamp} WHERE namespace_id = {ns};
        UPDATE fs_jobs SET simpro_id = (50000 + id)::text, {stamp}
            WHERE namespace_id = {ns} AND kind = 'project';
        UPDATE fs_asset_test_history SET simpro_id = (70000 + id)::text, {stamp}
            WHERE namespace_id = {ns} AND tested_at < NOW() - interval '7 days';
    """)
    # One asset edited in OpsAPI since its last sync: the pull will take Simpro's copy and log the conflict.
    sql(f"""UPDATE fs_assets SET location_detail = 'Roof — edited in OpsAPI after the last sync',
            simpro_sync_state = 'pending', updated_at = NOW() WHERE namespace_id = {ns} AND asset_tag = 'NBS-VRV-02'""")

    pull = s.call("owner", "POST", "/api/v2/field-service/simpro/pull", {})
    push = s.call("owner", "POST", "/api/v2/field-service/simpro/push", {"limit": 500})
    return {"pull": pull.get("results"), "push": push.get("results")}


def main() -> None:
    if dbs.DB in ("opsapi-diytaxreturn",) or "prod" in dbs.DB:
        die(f"refusing to seed database '{dbs.DB}'")
    s = dbs.Seeder(dbs.seed_password(), dbs.test_otp())
    dbs.setup_reference_data(s)

    print("P1. Brand the workspace as DBS Ltd")
    brand_workspace(s)
    print("P2. Team profiles and licences")
    employees = team_profiles(s)
    n_licences = licences(s, employees)
    print("P3. Customers, contacts and sites from the case studies")
    customer_uuids = customers(s)
    day_story_customers(s)
    site_uuids = sites(s, customer_uuids)
    print("P4. Contracts and asset types")
    contract_uuids = contracts(s, customer_uuids)
    type_defs = asset_types(s)
    print("P5. Asset register")
    plan = assets(s, site_uuids, type_defs, contract_uuids)
    print(f"P6. {HISTORY_MONTHS} months of surveys, recorded by the engineers ({len(plan)} assets)")
    survey = survey_history(s, plan, type_defs, contract_uuids)
    print("P7. Projects with cost centres")
    project_totals = projects(s, customer_uuids, site_uuids)
    print("P8. Quotations")
    n_quotes = quotes(s)
    print("P9. Simpro connection, first pull and push")
    sync = simpro(s)

    print(f"Done. {len(customer_uuids)} customers, {len(site_uuids)} sites, {len(contract_uuids)} contracts, "
          f"{len(plan)} assets, {survey['tests']} surveys ({survey['fails']} failed, {survey['advisories']} "
          f"advisory, {survey['overdue_levels']} schedules left overdue), {project_totals['projects']} projects "
          f"(£{project_totals['value']:,.0f}), {n_licences} licences, {n_quotes} quotes.")
    print("Simpro pull:", json.dumps(sync["pull"]))
    print("Simpro push:", json.dumps(sync["push"]))


if __name__ == "__main__":
    try:
        main()
    except dbs.APIFailure as failure:
        die(str(failure))
