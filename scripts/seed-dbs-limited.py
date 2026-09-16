#!/usr/bin/env python3
"""Seed the LOCAL OPSAPI with a realistic "DBS Limited" field-service workspace.

DBS Limited is modelled as an air conditioning and refrigeration contractor working across London
and the South East: an operations director, two service managers, a service desk coordinator and
six engineers. Their customers are commercial (a managing agent's offices, a restaurant group, a
convenience store chain, a GP practice, a data centre, a hotel, a primary school) plus one
domestic heat pump owner, each with real-looking sites, contacts, access notes and plant.

The working day is generated relative to *now*, so the app always opens on a believable board:
engineers on site (one on an out-of-hours call-out), the day's finished work with F-Gas records
and customer sign-offs, a no-access visit, tomorrow's bookings, parts waiting for approval, a
multi-day installation, a quotation, and invoices that are draft, sent, overdue and paid.

Everything goes through the real API, performed by the person who would do it: the service desk
logs requests, managers convert, book and approve, engineers travel, check in with GPS, tick
checklists, log labour and materials and check out. The API stamps NOW(), so each step is then
moved back to when it "happened".

Never run this against a shared or production database. Defaults target the isolated stack in the
README ("Local OPSAPI for Simulator testing"); run scripts/local-opsapi-fs-seed.sh first (this
reuses its password and the container's TEST_OTP_CODE). Staff emails end in @e2e.invalid so the
server's OTP_SUPPRESS_FOR_EMAIL_REGEX stops sign-in codes being emailed; customer emails use the
reserved .example domain.

    scripts/seed-dbs-limited.py            # first run
    scripts/seed-dbs-limited.py --reset    # rebuild requests, jobs, visits and invoices around now

Writes build/dbs-limited.env (mode 600, git-ignored) with the sign-in usernames.
"""
from __future__ import annotations

import argparse
import heapq
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from contextlib import contextmanager
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parent.parent
API = os.environ.get("API", "http://127.0.0.1:4011")
API_CONTAINER = os.environ.get("API_CONTAINER", "wslcrm-opsapi-pr610")
PG_CONTAINER = os.environ.get("PG_CONTAINER", "opsapi-postgres-dev-db")
DB = os.environ.get("DB", "opsapi-wslcrm-pr610")
FS_ENV = ROOT / "build" / "local-fs-test.env"
OUT = ROOT / "build" / "dbs-limited.env"

LONDON = ZoneInfo("Europe/London")
NOW = datetime.now(timezone.utc).replace(microsecond=0)
VAT = 20

# ---------------------------------------------------------------------------------------------
# Reference data
# ---------------------------------------------------------------------------------------------

NAMESPACE = {"name": "DBS Limited", "slug": "dbs-limited",
             "description": "Air conditioning, refrigeration and heat pumps — London & South East"}

OWNER = {"key": "owner", "first": "Owen", "last": "Sinclair", "username": "owen.sinclair"}

# key, first, last, username, namespace role
STAFF = [
    ("claire", "Claire", "Donnelly", "claire.donnelly", "service_manager"),   # service manager, reactive
    ("marcus", "Marcus", "Reid", "marcus.reid", "service_manager"),          # contracts manager, PPM + installs
    ("aisha", "Aisha", "Rahman", "aisha.rahman", "telecaller"),              # service desk coordinator
    ("tom", "Tom", "Fletcher", "tom.fletcher", "engineer"),                  # senior AC & refrigeration engineer
    ("kwame", "Kwame", "Mensah", "kwame.mensah", "engineer"),                # refrigeration engineer (retail)
    ("jake", "Jake", "Harrison", "jake.harrison", "engineer"),               # installation engineer
    ("ryan", "Ryan", "O'Connell", "ryan.oconnell", "engineer"),              # installation engineer's mate
    ("piotr", "Piotr", "Kowalski", "piotr.kowalski", "engineer"),            # PPM & F-Gas engineer
    ("sanjay", "Sanjay", "Mistry", "sanjay.mistry", "engineer"),             # AC & heat pump engineer
]


def staff_email(username: str) -> str:
    return f"{username}.dbs@e2e.invalid"


CUSTOMERS = {
    "northgate": {
        "first_name": "Northgate Property Management", "email": "helen.marsh@northgate-pm.example",
        "phone": "+44 20 7946 0321",
        "notes": "Managing agent. Contact: Helen Marsh, Facilities Manager. Quarterly PPM contract NPM-2024-117.",
    },
    "olive": {
        "first_name": "The Olive Tree Restaurants Ltd", "email": "marco.bellini@olivetree-restaurants.example",
        "phone": "+44 7700 900412",
        "notes": "Contact: Marco Bellini, Operations Manager. 4-hour response on cold rooms, 24/7.",
    },
    "freshway": {
        "first_name": "FreshWay Convenience Stores Ltd", "email": "maintenance@freshway-stores.example",
        "phone": "+44 7700 900587",
        "notes": "Contact: Gary Thompson, Estates & Maintenance Manager. PO number required on every invoice.",
    },
    "riverside": {
        "first_name": "Riverside Medical Practice", "email": "practice.manager@riverside-medical.example",
        "phone": "+44 20 7946 0733",
        "notes": "Contact: Sarah Collins, Practice Manager. Vaccine fridges are critical — same-day response.",
    },
    "brightwell": {
        "first_name": "Brightwell Data Centres Ltd", "email": "facilities@brightwell-dc.example",
        "phone": "+44 118 496 0214",
        "notes": "Contact: Priya Shah, Critical Facilities Manager. Access booked via the customer portal; RAMS 48h ahead.",
    },
    "kensington": {
        "first_name": "Kensington Grange Hotel", "email": "chief.engineer@kensingtongrange.example",
        "phone": "+44 20 7946 0968",
        "notes": "Contact: Andrew Blake, Chief Engineer. Guest-room complaints are high priority.",
    },
    "oakfield": {
        "first_name": "Oakfield Primary School", "email": "business.manager@oakfield-primary.example",
        "phone": "+44 20 7946 0529",
        "notes": "Contact: Janet Holloway, School Business Manager. Invoices to the school office, 30 days.",
    },
    "whitfield": {
        "first_name": "James", "last_name": "Whitfield", "email": "james.whitfield@mailbox.example",
        "phone": "+44 7700 900766",
        "notes": "Domestic. Mitsubishi Ecodan installed by DBS in 2023, annual service plan.",
    },
}

# key: customer, name, line1, city, county, postcode, contact, contact phone, access notes, lat, lng
SITES = {
    "aldgate": ("northgate", "Aldgate House", "33 Aldgate High Street", "London", "Greater London", "EC3N 1AH",
                "Dean Wallace (security desk)", "+44 20 7946 0455",
                "Sign in at the ground-floor security desk. Roof plant via the service lift to level 9, then the "
                "fixed ladder — permit to work from the building manager.", 51.5138, -0.0766),
    "towerbridge": ("northgate", "Tower Bridge Court", "224 Tower Bridge Road", "London", "Greater London", "SE1 2UP",
                    "Lucy Chen (building manager)", "+44 20 7946 0612",
                    "Loading bay on Druid Street. Level 2 meeting rooms are live: noisy works before 09:00 or after "
                    "17:00 only.", 51.4995, -0.0785),
    "olive_cg": ("olive", "The Olive Tree — Covent Garden", "12 Maiden Lane", "London", "Greater London", "WC2E 7NA",
                 "Luca Romano (head chef)", "+44 7700 900418",
                 "Engineers use the rear door on Exchange Court. Cold room is behind the kitchen pass. Avoid "
                 "12:00–14:30 and 18:00–21:30 service unless it's an emergency.", 51.5109, -0.1232),
    "olive_rich": ("olive", "The Olive Tree — Richmond", "5 Hill Street", "Richmond", "Surrey", "TW9 1SX",
                   "Hannah Price (general manager)", "+44 7700 900433",
                   "Condensing units on the flat roof above the kitchen, access by loft hatch in the office.",
                   51.4598, -0.3066),
    "streatham": ("freshway", "FreshWay Streatham (Store 114)", "212 Streatham High Road", "London", "Greater London",
                  "SW16 1BB", "Deborah Okafor (store manager)", "+44 20 7946 0874",
                  "Store open 07:00–23:00. Condensing units in the rear yard; yard key is kept at the tills.",
                  51.4296, -0.1310),
    "croydon": ("freshway", "FreshWay Croydon (Store 087)", "41 London Road", "Croydon", "Surrey", "CR0 2RE",
                "Imran Qureshi (store manager)", "+44 20 7946 0891",
                "Park in the service yard off Tamworth Road. Freezer room is at the back of the warehouse.",
                51.3805, -0.1045),
    "riverside": ("riverside", "Riverside Medical Centre", "18 Wood Street", "Kingston upon Thames", "Surrey", "KT1 1UG",
                  "Sarah Collins (practice manager)", "+44 20 7946 0733",
                  "Vaccine fridges are in the treatment room corridor. Engineers must not move stock — the duty nurse "
                  "transfers vaccines.", 51.4123, -0.3052),
    "brightwell": ("brightwell", "Brightwell DC2 — Slough", "Unit 4, Edinburgh Avenue", "Slough", "Berkshire", "SL1 4UF",
                   "NOC shift lead", "+44 118 496 0220",
                   "24/7 site. Photo ID and a portal access booking required. Escorted in data halls; no hot works "
                   "without a permit.", 51.5254, -0.6268),
    "kensington": ("kensington", "Kensington Grange — Harrington Gardens", "27 Harrington Gardens", "London", "Greater London",
                   "SW7 4JU", "Andrew Blake (chief engineer)", "+44 20 7946 0968",
                   "Report to reception, then the maintenance office in the basement. VRF plant on the roof via the "
                   "guest lift to level 6 — harness point by the hatch.", 51.4935, -0.1830),
    "oakfield": ("oakfield", "Oakfield Primary — main building", "Oakfield Road", "Croydon", "Surrey", "CR0 2UD",
                 "Janet Holloway (school business manager)", "+44 20 7946 0529",
                 "Sign in at the school office and wear a visitor lanyard. Classroom works before 08:30 or after "
                 "15:30 in term time.", 51.3830, -0.0985),
    "whitfield": ("whitfield", "14 Pewley Hill", "14 Pewley Hill", "Guildford", "Surrey", "GU1 3SN",
                  "James Whitfield", "+44 7700 900766",
                  "Heat pump at the side of the house through the side gate. Please ring before arriving — dog at home.",
                  51.2345, -0.5680),
}

# Serviced equipment (the app's "assets" are store products): sku, name, description
ASSETS = {
    "vrv": ("DAI-RXYSQ8TY1", "Daikin VRV IV-S RXYSQ8TY1 heat pump", "Rooftop VRF condenser, R410A, 22.4 kW"),
    "pka": ("MIT-PKA-M50KAL", "Mitsubishi Electric PKA-M50KAL wall unit", "High-wall indoor unit, R32, 5.0 kW"),
    "cassette": ("TOS-RAV-RM1101UTP", "Toshiba RAV-RM1101UTP 4-way cassette", "Ceiling cassette, R410A, 10 kW"),
    "vaccine": ("LIE-LKUEXV1610", "Liebherr LKUexv 1610 MediLine vaccine fridge", "Pharmacy fridge, 141 L, R600a"),
    "coldroom": ("TEC-CAJ4492Z", "Tecumseh CAJ4492Z cold room condensing unit", "Hermetic condensing unit, R448A"),
    "multideck": ("ARN-OSAKA2-375", "Arneg Osaka 2 multideck chiller 3.75 m", "Remote dairy multideck, R448A"),
    "crac": ("VER-PDX-PX025", "Vertiv Liebert PDX PX025 CRAC unit", "Downflow DX close control, R410A, 25 kW"),
    "chiller": ("CAR-30RB-0262R", "Carrier AquaSnap 30RB-0262R chiller", "Air-cooled scroll chiller, R410A, 260 kW"),
    "ecodan": ("MIT-PUZ-WM85VAA", "Mitsubishi Electric Ecodan PUZ-WM85VAA heat pump", "Air source heat pump, R32, 8.5 kW"),
    "fujitsu": ("FUJ-ASYG12KMCC", "Fujitsu ASYG12KMCC wall split", "Server room wall split, R32, 3.4 kW"),
    "freezer": ("SEA-KEC70-6", "Searle KEC70-6 freezer room evaporator", "Low-temperature evaporator with door heater"),
    "ice": ("HOS-IM-65NE", "Hoshizaki IM-65NE ice machine", "Self-contained cube ice maker, 60 kg/day"),
    "ducted": ("DAI-FBA71A", "Daikin FBA71A ducted unit", "Concealed ducted indoor unit, R32, 7.1 kW"),
}

# sku: name, category, unit cost, unit price, stock, reorder level
PARTS = {
    "RUN-CAP-35": ("Run capacitor 35µF 450V", "Electrical", 6.20, 18.50, 14, 6),
    "CONT-25A-230": ("Contactor 25A, 230V coil", "Electrical", 22.00, 48.00, 4, 3),
    "LP-SW-KP1": ("Low pressure switch — Danfoss KP1", "Controls", 28.00, 58.00, 6, 3),
    "CTRL-PAR-41MAA": ("Wired remote controller — Mitsubishi PAR-41MAA", "Controls", 95.00, 165.00, 2, 2),
    "FAN-LIE-6118010": ("Condenser fan motor — Liebherr 6118010", "Motors", 88.00, 154.00, 0, 1),
    "FAN-MTR-EC-250": ("EC condenser fan motor 250 mm", "Motors", 118.00, 196.00, 3, 2),
    "HTR-DOOR-4M": ("Freezer door frame heater 4 m, 230V", "Electrical", 31.00, 64.00, 2, 2),
    "FD-DML-163": ("Filter drier Danfoss DML 163s, 3/8\" solder", "Refrigeration", 9.40, 24.00, 22, 10),
    "TXV-DAN-TE2": ("Thermostatic expansion valve — Danfoss TE2", "Refrigeration", 62.00, 118.00, 3, 2),
    "REF-R32-KG": ("R32 refrigerant (per kg)", "Refrigerant", 18.00, 42.00, 36, 18),
    "REF-R410A-KG": ("R410A refrigerant (per kg)", "Refrigerant", 24.00, 55.00, 9, 20),
    "REF-R448A-KG": ("R448A refrigerant (per kg)", "Refrigerant", 21.00, 48.00, 18, 12),
    "FILT-G4-592": ("Pleated panel filter G4 592×592×48", "Filters", 4.10, 11.50, 48, 24),
    "COIL-CLEAN-5L": ("Coil cleaner, non-acid 5 L", "Consumables", 16.00, 32.00, 6, 3),
    "PUMP-ASPEN-MO": ("Condensate pump — Aspen Mini Orange", "Drainage", 64.00, 115.00, 7, 4),
    "PIPE-CU-14": ("Copper pipe 1/4\" (per m)", "Pipework", 3.20, 8.00, 120, 40),
    "PIPE-CU-38": ("Copper pipe 3/8\" (per m)", "Pipework", 4.60, 11.00, 95, 40),
    "INS-ARMA-13": ("Armaflex insulation 13 mm (per m)", "Pipework", 1.10, 3.50, 140, 50),
    "CABLE-4C-15": ("Interconnecting cable 4-core 1.5 mm² (per m)", "Electrical", 0.95, 2.80, 200, 50),
}

# name: rate, colour, description, [(phase, hours, requires signoff, checklist)]
JOB_TYPES = {
    "Reactive breakdown": (85, "#dc2626", "Breakdown call-out: diagnose, repair and recommission", [
        ("Diagnose", 1, False, ["Safe isolation and lock-off", "Read fault codes and controller history",
                                "Record suction/discharge pressures and temperatures",
                                "Inspect electrical terminations", "Photograph the fault and rating plate"]),
        ("Repair & recommission", 2, True, ["Replace failed component", "Strength and tightness test with OFN",
                                            "Evacuate and recharge (record kg)", "Run test and record temperatures",
                                            "Customer sign-off"]),
    ]),
    "Emergency call-out": (128, "#b91c1c", "Out-of-hours emergency attendance, 4-hour response", [
        ("Emergency attendance", 2, True, ["Make safe", "Diagnose fault", "Protect stock / temporary cooling",
                                           "Repair or advise next steps", "Brief the duty manager"]),
    ]),
    "Planned maintenance (PPM)": (68, "#0284c7", "Contracted planned preventative maintenance to SFG20", [
        ("PPM service visit", 3, True, ["Clean or replace filters", "Clean evaporator and condenser coils",
                                        "Check condensate drain and pump", "Check electrical terminations and isolators",
                                        "Record operating pressures and temperatures",
                                        "F-Gas leak check where required", "Update asset log and service label"]),
    ]),
    "Installation": (72, "#7c3aed", "Supply, install and commission", [
        ("Site survey", 2, False, ["Confirm unit positions with the client", "Check supply and isolator location",
                                   "Plan pipe and condensate routes", "Issue RAMS"]),
        ("First fix", 16, False, ["Fit brackets and wall sleeves", "Run and braze pipework under nitrogen",
                                  "Run interconnecting cable", "Install condensate drainage"]),
        ("Second fix & commissioning", 8, True, ["Mount indoor and outdoor units",
                                                 "Strength and tightness test (24 h hold)",
                                                 "Triple evacuate to 500 microns", "Charge and commission",
                                                 "Controls set-up and handover demonstration"]),
    ]),
    "F-Gas leak check": (65, "#059669", "Statutory F-Gas leak check and log update", [
        ("Leak check", 2, False, ["Direct leak test on joints and valves", "Check the leak detection system",
                                  "Update the F-Gas log", "Label the equipment"]),
    ]),
}

# Established business: numbering continues from where the old system left off.
SEQUENCES = {"fs_request_sequences": ("SR", 1183), "fs_job_sequences": ("JOB", 2406)}
INVOICE_SEQUENCE = ("INV", 4817)


# ---------------------------------------------------------------------------------------------
# Infrastructure: SQL, API, time
# ---------------------------------------------------------------------------------------------

def die(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    sys.exit(1)


def lit(value) -> str:
    if value is None:
        return "NULL"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return repr(value)
    return "'" + str(value).replace("'", "''") + "'"


def sql(query: str) -> list[list[str]]:
    result = subprocess.run(
        ["docker", "exec", "-i", PG_CONTAINER, "sh", "-c",
         f'psql -U "$POSTGRES_USER" -d "{DB}" -v ON_ERROR_STOP=1 -AtqX'],
        input=query, capture_output=True, text=True)
    if result.returncode != 0:
        die(f"SQL failed: {result.stderr.strip()}\n{query[:600]}")
    return [line.split("|") for line in result.stdout.splitlines() if line]


def sql_value(query: str) -> str | None:
    rows = sql(query)
    return rows[0][0] if rows and rows[0] and rows[0][0] != "" else None


def utc(moment: datetime) -> str:
    """The API's naive-UTC timestamp format."""
    return moment.astimezone(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")


def local_today() -> date:
    return NOW.astimezone(LONDON).date()


def shift_workdays(day: date, n: int) -> date:
    step = 1 if n > 0 else -1
    for _ in range(abs(n)):
        day += timedelta(days=step)
        while day.weekday() >= 5:
            day += timedelta(days=step)
    return day


def at(day: date, hhmm: str) -> datetime:
    hour, minute = map(int, hhmm.split(":"))
    return datetime(day.year, day.month, day.day, hour, minute, tzinfo=LONDON)


def ago(minutes: float) -> datetime:
    return NOW - timedelta(minutes=minutes)


# "The round" is the most recent full working day already worked: today once the day's work is
# done (from 18:00 on a weekday), otherwise the previous working day. NEXT is the working day
# after it, so a morning run shows today's bookings ahead and an evening run shows tomorrow's.
_now_local = NOW.astimezone(LONDON)
ROUND = local_today() if (_now_local.weekday() < 5 and _now_local.hour >= 18) else shift_workdays(local_today(), -1)
NEXT = shift_workdays(ROUND, 1)
OUT_OF_HOURS = not (_now_local.weekday() < 5 and 8 <= _now_local.hour < 18)


def before(n: int, hhmm: str) -> datetime:
    """A time on the working day n days before the round (n=0 is the round itself)."""
    return at(shift_workdays(ROUND, -n) if n else ROUND, hhmm)


def ahead(n: int, hhmm: str) -> datetime:
    """A time on the working day n days after NEXT (n=0 is NEXT)."""
    return at(shift_workdays(NEXT, n) if n else NEXT, hhmm)


class APIFailure(Exception):
    pass


class Seeder:
    SHIFTED = {
        "fs_service_requests": ["created_at", "updated_at", "first_response_at", "resolved_at", "closed_at"],
        "fs_jobs": ["created_at", "updated_at", "started_at", "completed_at", "invoiced_at"],
        "fs_job_phases": ["created_at", "updated_at", "started_at", "completed_at", "signed_off_at"],
        "fs_visits": ["created_at", "updated_at", "checked_in_at", "checked_out_at", "customer_signed_at"],
        "fs_job_items": ["created_at", "updated_at", "approved_at"],
        "fs_job_activity": ["created_at"],
        "invoices": ["created_at", "updated_at", "sent_at", "paid_at"],
        "invoice_payments": ["created_at", "updated_at"],
    }

    def __init__(self, password: str, otp: str):
        self.password = password
        self.otp = otp
        self.tokens: dict[str, str] = {}
        self.identifiers: dict[str, str] = {}
        self.users: dict[str, dict] = {}
        self.ns_uuid = ""
        self.ns_id = 0
        self.customers: dict[str, str] = {}
        self.sites: dict[str, str] = {}
        self.assets: dict[str, str] = {}
        self.parts: dict[str, str] = {}
        self.job_types: dict[str, str] = {}
        self.mark: str | None = None

    # -- HTTP ---------------------------------------------------------------------------------

    def _request(self, method: str, path: str, token: str | None, body=None, form: dict | None = None):
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
        if self.ns_uuid:
            headers["X-Namespace-Id"] = self.ns_uuid
        request = urllib.request.Request(API + path, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                raw = response.read()
                return response.status, (json.loads(raw) if raw else {})
        except urllib.error.HTTPError as error:
            raw = error.read()
            try:
                return error.code, json.loads(raw)
            except ValueError:
                return error.code, {"raw": raw.decode(errors="replace")[:300]}

    def login(self, who: str) -> str:
        identifier = self.identifiers[who]
        for attempt in range(8):
            status, payload = self._request("POST", "/auth/login", None,
                                            form={"identifier": identifier, "password": self.password})
            if status == 429:
                time.sleep(15)
                continue
            if status != 200 or "session_token" not in payload:
                raise APIFailure(f"login {who}: {status} {payload}")
            status, verified = self._request("POST", "/auth/2fa/verify", None,
                                             body={"session_token": payload["session_token"], "code": self.otp})
            if status == 429:
                time.sleep(15)
                continue
            if status != 200:
                raise APIFailure(f"2FA {who}: {status} {verified}")
            self.tokens[who] = verified["token"]
            return self.tokens[who]
        raise APIFailure(f"login {who}: rate limited")

    def call(self, who: str, method: str, path: str, body=None, ok=(200, 201)):
        token = self.tokens.get(who) or self.login(who)
        status, payload = self._request(method, path, token, body)
        if status == 401:
            token = self.login(who)
            status, payload = self._request(method, path, token, body)
        if status not in ok:
            raise APIFailure(f"{who} {method} {path} -> {status}: {json.dumps(payload)[:500]}")
        if isinstance(payload, dict) and "data" in payload and payload.get("success") is not False:
            return payload["data"]
        return payload

    # -- Time travel ----------------------------------------------------------------------------

    @contextmanager
    def happened(self, moment: datetime):
        """Everything written inside the block is re-stamped as having happened at `moment`.

        Rows are matched by timestamps at or after the mark taken before the block (less a
        second, as Lapis models stamp whole seconds). Every earlier block has already been
        moved into the past, so only this block's writes match.
        """
        if moment >= NOW:
            raise ValueError(f"{moment} is not in the past")
        mark = self.mark or sql_value("SELECT (date_trunc('second', clock_timestamp() AT TIME ZONE 'UTC') "
                                      "- interval '1 second')::text")
        yield
        target = lit(utc(moment)) + "::timestamp"
        statements = ["BEGIN;"]
        for table, columns in self.SHIFTED.items():
            assignments = ", ".join(
                f"{c} = CASE WHEN {c} >= '{mark}' THEN {target} + ({c} - '{mark}') ELSE {c} END" for c in columns)
            matched = " OR ".join(f"{c} >= '{mark}'" for c in columns)
            statements.append(f"UPDATE {table} SET {assignments} WHERE namespace_id = {self.ns_id} AND ({matched});")
        statements.append(f"""
            UPDATE invoice_line_items SET created_at = {target} + (created_at - '{mark}'),
                updated_at = {target} + (updated_at - '{mark}')
            WHERE created_at >= '{mark}' AND invoice_id IN (SELECT id FROM invoices WHERE namespace_id = {self.ns_id});
            UPDATE notifications SET created_at = {target} + (created_at - '{mark}'),
                updated_at = {target} + (updated_at - '{mark}')
            WHERE created_at >= '{mark}' AND user_id IN
                (SELECT user_id FROM namespace_members WHERE namespace_id = {self.ns_id});
            UPDATE fs_job_phases p SET checklist = (
                SELECT jsonb_agg(CASE WHEN e ? 'done_at' AND (e->>'done_at')::timestamp >= '{mark}'
                    THEN jsonb_set(e, '{{done_at}}', to_jsonb(to_char({target} + ((e->>'done_at')::timestamp - '{mark}'),
                                                                     'YYYY-MM-DD HH24:MI:SS')))
                    ELSE e END ORDER BY ord)
                FROM jsonb_array_elements(p.checklist) WITH ORDINALITY AS x(e, ord))
            WHERE p.namespace_id = {self.ns_id} AND jsonb_typeof(p.checklist) = 'array'
              AND EXISTS (SELECT 1 FROM jsonb_array_elements(p.checklist) e
                          WHERE e ? 'done_at' AND (e->>'done_at')::timestamp >= '{mark}');
            COMMIT;
            SELECT (date_trunc('second', clock_timestamp() AT TIME ZONE 'UTC') - interval '1 second')::text;""")
        self.mark = sql_value("\n".join(statements))

    def run(self, stories) -> None:
        """Runs story generators interleaved in time order. Each yields the moment its next step happens."""
        queue = []
        for index, story in enumerate(stories):
            moment = next(story, None)
            if moment is not None:
                heapq.heappush(queue, (moment, index, story))
        steps = 0
        while queue:
            moment, index, story = heapq.heappop(queue)
            with self.happened(moment):
                upcoming = next(story, None)
            steps += 1
            if upcoming is not None:
                if upcoming < moment:
                    raise ValueError(f"{story.__name__} goes back in time: {upcoming} after {moment}")
                heapq.heappush(queue, (upcoming, index, story))
        print(f"   {steps} steps")

    # -- Domain actions -------------------------------------------------------------------------

    def uuid_of(self, who: str) -> str:
        return self.users[who]["uuid"]

    def site_fields(self, site: str) -> dict:
        s = SITES[site]
        return {"service_address": f"{s[2]}, {s[3]}", "service_postcode": s[5]}

    def log_request(self, who, customer, site, title, description, fault, channel="phone", priority="normal",
                    reported_by=None, asset=None, product_ref=None, response_hours=None, resolve_hours=None,
                    logged_at=None):
        body = {"title": title, "description": description, "fault_category": fault, "channel": channel,
                "priority": priority, "reported_by": reported_by, "customer_uuid": self.customers[customer],
                "product_ref": product_ref, **self.site_fields(site)}
        if asset:
            body["product_uuid"] = self.assets[asset]
        if logged_at and response_hours:
            body["sla_response_due_at"] = utc(logged_at + timedelta(hours=response_hours))
        if logged_at and resolve_hours:
            body["sla_resolve_due_at"] = utc(logged_at + timedelta(hours=resolve_hours))
        request = self.call(who, "POST", "/api/v2/field-service/service-requests", body)
        # API-NOTES 44: site_uuid is dropped on create, so it is set with a follow-up PUT (as the app does).
        self.call(who, "PUT", f"/api/v2/field-service/service-requests/{request['uuid']}",
                  {"site_uuid": self.sites[site]})
        return request

    def request_status(self, who, request, status, notes=None):
        self.call(who, "POST", f"/api/v2/field-service/service-requests/{request['uuid']}/status",
                  {"status": status, "resolution_notes": notes})

    def convert(self, who, request, job_type, site, customer_reference=None, due=None, title=None, notes=None):
        result = self.call(who, "POST", f"/api/v2/field-service/service-requests/{request['uuid']}/convert-to-job",
                           {"job_type_uuid": self.job_types[job_type], "service_manager_uuid": self.uuid_of(who),
                            "due_date": due.isoformat() if due else None, "title": title})
        return self.finish_job_setup(who, result["job_uuid"], site, customer_reference, notes)

    def new_job(self, who, customer, site, job_type, title, description, priority="normal", asset=None,
                product_ref=None, customer_reference=None, due=None, notes=None, estimated_hours=None):
        body = {"title": title, "description": description, "priority": priority,
                "job_type_uuid": self.job_types[job_type], "customer_uuid": self.customers[customer],
                "service_manager_uuid": self.uuid_of(who), "product_ref": product_ref,
                "due_date": due.isoformat() if due else None, "estimated_hours": estimated_hours,
                **self.site_fields(site)}
        if asset:
            body["product_uuid"] = self.assets[asset]
        job = self.call(who, "POST", "/api/v2/field-service/jobs", body)
        return self.finish_job_setup(who, job["uuid"], site, customer_reference, notes)

    def finish_job_setup(self, who, job_uuid, site, customer_reference, notes):
        update = {"site_uuid": self.sites[site]}   # dropped on create (API-NOTES 44)
        if customer_reference:
            update["customer_reference"] = customer_reference
        if notes:
            update["notes"] = notes
        self.call(who, "PUT", f"/api/v2/field-service/jobs/{job_uuid}", update)
        return self.job(who, job_uuid)

    def job(self, who, job_uuid):
        job = self.call(who, "GET", f"/api/v2/field-service/jobs/{job_uuid}")
        job["phase"] = {p["name"]: p["uuid"] for p in job.get("phases", [])}
        return job

    def book(self, who, job, engineer, start: datetime, end: datetime, phase=None, instructions=None):
        body = {"engineer_user_uuid": self.uuid_of(engineer), "scheduled_start": utc(start),
                "scheduled_end": utc(end), "instructions": instructions}
        if phase:
            body["phase_uuid"] = job["phase"][phase]
        return self.call(who, "POST", f"/api/v2/field-service/jobs/{job['uuid']}/visits", body)["visit"]["uuid"]

    def on_my_way(self, engineer, visit):
        self.call(engineer, "POST", f"/api/v2/field-service/visits/{visit}/en-route", {})

    def arrive(self, engineer, visit, site):
        lat, lng = SITES[site][9], SITES[site][10]
        self.call(engineer, "POST", f"/api/v2/field-service/visits/{visit}/check-in",
                  {"latitude": round(lat + 0.00012, 6), "longitude": round(lng - 0.00009, 6)})

    def tick(self, who, job, phase, indexes):
        for index in indexes:
            self.call(who, "POST", f"/api/v2/field-service/job-phases/{job['phase'][phase]}/checklist/{index}",
                      {"done": True})

    def labour(self, engineer, job, visit, hours, rate, category="engineer_nt", description=None):
        names = {"engineer_nt": "Engineer — normal time", "engineer_ot": "Engineer — overtime",
                 "mate_nt": "Mate — normal time", "mate_ot": "Mate — overtime"}
        return self.call(engineer, "POST", f"/api/v2/field-service/jobs/{job['uuid']}/items",
                         {"item_type": "labour", "labour_category": category, "visit_uuid": visit,
                          "description": description or names[category], "quantity": hours, "unit_price": rate,
                          "tax_rate": VAT})["uuid"]

    def part(self, engineer, job, visit, sku, quantity, item_type="part"):
        name, _, _, price, _, _ = PARTS[sku]
        return self.call(engineer, "POST", f"/api/v2/field-service/jobs/{job['uuid']}/items",
                         {"item_type": item_type, "description": name, "quantity": quantity, "unit_price": price,
                          "tax_rate": VAT, "visit_uuid": visit, "part_uuid": self.parts[sku], "part_number": sku,
                          "supplier": "Beijer Ref" if item_type == "part" else "DBS van stock"})["uuid"]

    def extra(self, who, job, item_type, description, quantity, price, visit=None, supplier=None, days=None):
        body = {"item_type": item_type, "description": description, "quantity": quantity, "unit_price": price,
                "tax_rate": VAT, "visit_uuid": visit, "supplier": supplier}
        if days is not None:
            body["days"] = days
        return self.call(who, "POST", f"/api/v2/field-service/jobs/{job['uuid']}/items", body)["uuid"]

    def approve(self, manager, *items):
        for item in items:
            self.call(manager, "POST", f"/api/v2/field-service/job-items/{item}/approve", {})

    def fgas(self, engineer, visit, refrigerant, cylinder, added, recovered, result, notes):
        self.call(engineer, "PUT", f"/api/v2/field-service/visits/{visit}",
                  {"refrigerant_type": refrigerant, "fgas_cylinder_ref": cylinder, "refrigerant_added_kg": added,
                   "refrigerant_recovered_kg": recovered, "leak_check_result": result, "leak_check_notes": notes})

    def leave(self, engineer, visit, site, summary, hours, signoff=None, complete_phase=False,
              follow_up=None):
        lat, lng = SITES[site][9], SITES[site][10]
        body = {"work_summary": summary, "labour_hours": hours, "customer_signoff_name": signoff,
                "complete_phase": complete_phase, "log_timesheet": False,
                "latitude": round(lat + 0.0001, 6), "longitude": round(lng - 0.0001, 6)}
        if follow_up:
            body.update({"follow_up_required": True, "follow_up_notes": follow_up})
        result = self.call(engineer, "POST", f"/api/v2/field-service/visits/{visit}/check-out", body)
        for warning in (result or {}).get("warnings") or []:
            print(f"   warning ({engineer} check-out): {warning}")

    def no_access(self, engineer, visit, reason):
        self.call(engineer, "POST", f"/api/v2/field-service/visits/{visit}/no-access", {"reason": reason})

    def phase_status(self, who, job, phase, status, signoff=None, notes=None, force=False):
        self.call(who, "POST", f"/api/v2/field-service/job-phases/{job['phase'][phase]}/status",
                  {"status": status, "signoff_name": signoff, "notes": notes, "force": force})

    def job_status(self, who, job, status, reason=None, force=False):
        self.call(who, "POST", f"/api/v2/field-service/jobs/{job['uuid']}/status",
                  {"status": status, "reason": reason, "force": force})

    def invoice(self, manager, job, issued: datetime, terms_days=30, notes=None):
        result = self.call(manager, "POST", f"/api/v2/field-service/jobs/{job['uuid']}/invoice",
                           {"labour_tax_rate": VAT, "notes": notes})
        issue_date = issued.astimezone(LONDON).date()
        sql(f"UPDATE invoices SET issue_date = {lit(issue_date.isoformat())}, "
            f"due_date = {lit((issue_date + timedelta(days=terms_days)).isoformat())}, payment_terms_days = {terms_days} "
            f"WHERE uuid = {lit(result['invoice_uuid'])}")
        return result

    def send_invoice(self, manager, invoice):
        # Marks it sent without emailing (the /email route would send real mail from this container).
        self.call(manager, "POST", f"/api/v2/invoices/{invoice['invoice_uuid']}/send", {})

    def pay(self, manager, invoice, paid_on: date, method, reference, amount=None):
        self.call(manager, "POST", f"/api/v2/invoices/{invoice['invoice_uuid']}/payments",
                  {"amount": amount if amount is not None else invoice["total_amount"], "payment_method": method,
                   "payment_date": paid_on.isoformat(), "reference_number": reference})


# ---------------------------------------------------------------------------------------------
# Setup: people, workspace, customers, sites, equipment, stock, job types
# ---------------------------------------------------------------------------------------------

def setup_reference_data(s: Seeder) -> None:
    print("1. Owner and workspace")
    owner_email = staff_email(OWNER["username"])
    sql(f"""
        INSERT INTO users (uuid, first_name, last_name, email, username, password, active, created_at, updated_at)
        SELECT gen_random_uuid()::text, {lit(OWNER['first'])}, {lit(OWNER['last'])}, {lit(owner_email)},
               {lit(OWNER['username'])}, crypt({lit(s.password)}, gen_salt('bf', 10)), true, NOW(), NOW()
        WHERE NOT EXISTS (SELECT 1 FROM users WHERE email = {lit(owner_email)});
        UPDATE users SET password = crypt({lit(s.password)}, gen_salt('bf', 10)), active = true
        WHERE email = {lit(owner_email)};""")
    s.identifiers["owner"] = OWNER["username"]
    for key, _, _, username, _ in STAFF:
        s.identifiers[key] = username

    ns = sql(f"SELECT uuid, id FROM namespaces WHERE slug = {lit(NAMESPACE['slug'])}")
    if not ns:
        created = s.call("owner", "POST", "/api/v2/user/namespaces", NAMESPACE)
        uuid = (created.get("namespace") or created.get("data") or created)["uuid"]
        s.call("owner", "PUT", "/api/v2/user/namespace-settings", {"default_namespace_id": uuid})
        system_ns = sql_value("SELECT uuid FROM namespaces WHERE slug = 'system'")
        if system_ns:   # undo the resolver's auto-join of a brand-new user into System
            s.ns_uuid = system_ns
            s.call("owner", "POST", "/api/v2/namespace/leave", {}, ok=(200, 201, 400, 403, 404))
        ns = sql(f"SELECT uuid, id FROM namespaces WHERE slug = {lit(NAMESPACE['slug'])}")
    s.ns_uuid, s.ns_id = ns[0][0], int(ns[0][1])
    sql(f"UPDATE namespaces SET created_at = NOW() - interval '6 years' WHERE id = {s.ns_id}")

    print("2. Staff")
    for key, first, last, username, role in STAFF:
        email = staff_email(username)
        if not sql_value(f"SELECT 1 FROM users WHERE email = {lit(email)}"):
            s.call("owner", "POST", "/api/v2/users",
                   {"email": email, "username": username, "password": s.password, "first_name": first,
                    "last_name": last, "namespace_role": role})
    # PUT /api/v2/users writes a missing updated_by column, so activation is SQL.
    sql("UPDATE users SET active = true, updated_at = NOW() WHERE email LIKE '%.dbs@e2e.invalid'")
    for key, _, _, username, _ in [("owner", None, None, OWNER["username"], None)] + STAFF:
        row = sql(f"SELECT uuid, id FROM users WHERE username = {lit(username)}")
        if not row:
            die(f"user {username} was not created")
        s.users[key] = {"uuid": row[0][0], "id": int(row[0][1])}

    print("3. Store of serviced equipment")
    sql(f"""
        INSERT INTO stores (uuid, user_id, namespace_id, name, slug, description, status, currency, tax_rate,
                            city, country, created_at, updated_at)
        SELECT gen_random_uuid()::text, {s.users['owner']['id']}, {s.ns_id}, 'DBS Limited — serviced equipment',
               'dbs-limited-equipment', 'Customer plant maintained under contract or call-out', 'active', 'GBP', 0.2,
               'London', 'United Kingdom', NOW(), NOW()
        WHERE NOT EXISTS (SELECT 1 FROM stores WHERE slug = 'dbs-limited-equipment');""")
    store = sql_value("SELECT uuid FROM stores WHERE slug = 'dbs-limited-equipment'")
    for key, (sku, name, description) in ASSETS.items():
        uuid = sql_value(f"SELECT p.uuid FROM storeproducts p JOIN stores st ON st.id = p.store_id "
                         f"WHERE st.slug = 'dbs-limited-equipment' AND p.sku = {lit(sku)}")
        if not uuid:
            uuid = s.call("owner", "POST", "/api/v2/products",
                          {"store_id": store, "name": name, "sku": sku, "price": 1, "compare_price": 1,
                           "description": description, "track_inventory": False})["uuid"]
        s.assets[key] = uuid

    print("4. Customers and sites")
    for key, fields in CUSTOMERS.items():
        uuid = sql_value(f"SELECT uuid FROM customers WHERE namespace_id = {s.ns_id} AND email = {lit(fields['email'])}")
        if not uuid:
            uuid = s.call("claire", "POST", "/api/v2/customers", fields)["uuid"]
        s.customers[key] = uuid
    sql(f"UPDATE customers SET created_at = NOW() - interval '3 years' WHERE namespace_id = {s.ns_id}")
    for key, (customer, name, line1, city, county, postcode, contact, phone, notes, _, _) in SITES.items():
        fields = {"customer_uuid": s.customers[customer], "name": name, "address_line1": line1, "city": city,
                  "county": county, "postal_code": postcode, "country": "United Kingdom", "contact_name": contact,
                  "contact_phone": phone, "access_notes": notes}
        # Matched on the address, so renamed sites and edited notes are updated in place.
        uuid = sql_value(f"SELECT s.uuid FROM fs_sites s JOIN customers c ON c.id = s.customer_id "
                         f"WHERE s.namespace_id = {s.ns_id} AND c.uuid = {lit(s.customers[customer])} "
                         f"AND s.address_line1 = {lit(line1)} AND s.deleted_at IS NULL")
        if uuid:
            s.call("claire", "PUT", f"/api/v2/field-service/sites/{uuid}", fields)
        else:
            uuid = s.call("claire", "POST", "/api/v2/field-service/sites", fields)["uuid"]
        s.sites[key] = uuid
    sql(f"UPDATE fs_sites SET created_at = NOW() - interval '2 years' WHERE namespace_id = {s.ns_id}")

    print("5. Van and warehouse stock")
    for sku, (name, category, cost, price, stock, reorder) in PARTS.items():
        uuid = sql_value(f"SELECT uuid FROM fs_parts WHERE namespace_id = {s.ns_id} AND sku = {lit(sku)} "
                         f"AND deleted_at IS NULL")
        if not uuid:
            uuid = s.call("claire", "POST", "/api/v2/field-service/parts",
                          {"sku": sku, "name": name, "category": category, "unit_cost": cost, "unit_price": price,
                           "tax_rate": VAT, "stock_quantity": stock, "reorder_level": reorder})["uuid"]
        # Approving part lines decrements stock, so every run starts from the same levels.
        sql(f"UPDATE fs_parts SET stock_quantity = {stock} WHERE uuid = {lit(uuid)}")
        s.parts[sku] = uuid

    print("6. Job types and phase templates")
    existing = {t["name"]: t["uuid"] for t in
                s.call("claire", "GET", "/api/v2/field-service/job-types?include_inactive=true")}
    for name, (rate, colour, description, phases) in JOB_TYPES.items():
        if name not in existing:
            uuid = s.call("claire", "POST", "/api/v2/field-service/job-types",
                          {"name": name, "description": description, "default_hourly_rate": rate, "color": colour})["uuid"]
            for phase, hours, signoff, checklist in phases:
                s.call("claire", "POST", f"/api/v2/field-service/job-types/{uuid}/phases",
                       {"name": phase, "requires_visit": True, "requires_signoff": signoff,
                        "estimated_hours": hours, "checklist": checklist})
            existing[name] = uuid
        s.job_types[name] = existing[name]


def reset_work(s: Seeder) -> None:
    ns = s.ns_id
    sql(f"""
        BEGIN;
        DELETE FROM fs_job_activity WHERE namespace_id = {ns};
        DELETE FROM fs_job_photos WHERE namespace_id = {ns};
        DELETE FROM fs_job_items WHERE namespace_id = {ns};
        DELETE FROM fs_visits WHERE namespace_id = {ns};
        DELETE FROM fs_job_phases WHERE namespace_id = {ns};
        DELETE FROM fs_jobs WHERE namespace_id = {ns};
        DELETE FROM fs_service_requests WHERE namespace_id = {ns};
        DELETE FROM invoice_payments WHERE namespace_id = {ns};
        DELETE FROM invoice_line_items WHERE invoice_id IN (SELECT id FROM invoices WHERE namespace_id = {ns});
        DELETE FROM invoices WHERE namespace_id = {ns};
        DELETE FROM notifications WHERE type LIKE 'fs_%'
            AND user_id IN (SELECT user_id FROM namespace_members WHERE namespace_id = {ns});
        COMMIT;""")


def set_sequences(s: Seeder) -> None:
    for table, (prefix, number) in SEQUENCES.items():
        sql(f"INSERT INTO {table} (namespace_id, prefix, current_number, updated_at) "
            f"VALUES ({s.ns_id}, {lit(prefix)}, {number}, NOW()) ON CONFLICT (namespace_id) "
            f"DO UPDATE SET current_number = {number}, updated_at = NOW()")
    prefix, number = INVOICE_SEQUENCE
    sql(f"DELETE FROM invoice_sequences WHERE namespace_id = {s.ns_id}; "
        f"INSERT INTO invoice_sequences (namespace_id, prefix, current_number, created_at, updated_at) "
        f"VALUES ({s.ns_id}, {lit(prefix)}, {number}, NOW(), NOW())")


# ---------------------------------------------------------------------------------------------
# The stories. Each yields the moment its next step happens; the runner interleaves them in
# time order so statuses, stock and "last updated" stay consistent across jobs.
# ---------------------------------------------------------------------------------------------

def olive_richmond_ice_machine(s: Seeder):
    """Six working days ago: ice machine repaired. Invoiced, paid by bank transfer."""
    logged = before(7, "10:14")
    yield logged
    sr = s.log_request("aisha", "olive", "olive_rich", "Ice machine not making ice",
                       "Hannah reports the bar ice machine has stopped producing ice since last night. Water "
                       "supply is on and the unit is powered.", "No ice production", "phone", "high",
                       "Hannah Price (general manager)", "ice", "S/N H1204587", 4, 48, logged)
    yield before(7, "10:32")
    job = s.convert("claire", sr, "Reactive breakdown", "olive_rich", "OT-RICH-2291")
    visit = s.book("claire", job, "sanjay", before(6, "08:00"), before(6, "10:00"))
    yield before(6, "07:41")
    s.on_my_way("sanjay", visit)
    yield before(6, "08:06")
    s.arrive("sanjay", visit, "olive_rich")
    yield before(6, "08:20")
    s.tick("sanjay", job, "Diagnose", range(5))
    yield before(6, "09:35")
    s.tick("sanjay", job, "Repair & recommission", range(5))
    s.labour("sanjay", job, visit, 1.5, 85)
    valve = s.extra("sanjay", job, "part", "Water inlet valve — Hoshizaki 4A3622-01", 1, 46.00, visit, "Hoshizaki UK")
    yield before(6, "09:48")
    s.leave("sanjay", visit, "olive_rich",
            "Water inlet valve coil open circuit — no water to the evaporator plate. Replaced the inlet valve, "
            "flushed and sanitised the water system, ran two harvest cycles: 1.4 kg/cycle, normal.",
            1.5, signoff="Hannah Price")
    s.phase_status("sanjay", job, "Diagnose", "completed")
    s.phase_status("sanjay", job, "Repair & recommission", "completed", signoff="Hannah Price")
    yield before(6, "11:20")
    s.approve("claire", valve)
    s.job_status("claire", job, "completed")
    s.request_status("claire", sr, "resolved", "Inlet valve replaced; production back to normal.")
    yield before(6, "15:05")
    invoice = s.invoice("marcus", job, before(6, "15:05"), 30)
    s.send_invoice("marcus", invoice)
    s.request_status("claire", sr, "closed")
    yield before(1, "09:12")
    s.pay("marcus", invoice, before(1, "09:12").date(), "bank_transfer", "OLIVETREE BACS 88213")


def brightwell_humidifier(s: Seeder):
    """Six weeks ago: CRAC humidifier replaced. Invoice sent, now overdue."""
    day = shift_workdays(ROUND, -30)
    yield at(day, "08:55")
    sr = s.log_request("aisha", "brightwell", "brightwell", "CRAC 2 humidifier alarm",
                       "Portal ticket BW-INC-40317: humidifier fault on CRAC 2, data hall 3. Humidity drifting to "
                       "31% RH.", "Humidity fault", "portal", "high", "Priya Shah (critical facilities manager)",
                       "crac", "CRAC 2 — S/N 1911-PX025-0442", 4, 72, at(day, "08:55"))
    yield at(day, "09:20")
    job = s.convert("claire", sr, "Reactive breakdown", "brightwell", "BW-PO-118842")
    visit = s.book("claire", job, "kwame", at(shift_workdays(day, 1), "09:00"), at(shift_workdays(day, 1), "12:00"),
                   phase="Repair & recommission")
    next_day = shift_workdays(day, 1)
    yield at(next_day, "08:47")
    s.arrive("kwame", visit, "brightwell")
    yield at(next_day, "11:42")
    s.tick("kwame", job, "Diagnose", range(5))
    s.tick("kwame", job, "Repair & recommission", range(5))
    s.labour("kwame", job, visit, 3, 85)
    bottle = s.extra("kwame", job, "part", "Humidifier steam cylinder — Vertiv HC-10", 1, 212.00, visit, "Vertiv")
    yield at(next_day, "11:55")
    s.leave("kwame", visit, "brightwell",
            "Steam cylinder scaled and at end of life (conductivity alarm). Replaced cylinder, cleaned drain valve, "
            "humidity back to 45% RH setpoint within 40 minutes. Unit returned to the NOC.",
            3, signoff="Priya Shah", complete_phase=True)
    s.phase_status("kwame", job, "Diagnose", "completed")
    yield at(next_day, "14:10")
    s.approve("claire", bottle)
    s.job_status("claire", job, "completed")
    s.request_status("claire", sr, "resolved", "Steam cylinder replaced.")
    yield at(shift_workdays(next_day, 1), "10:00")
    invoice = s.invoice("marcus", job, at(shift_workdays(next_day, 1), "10:00"), 30)
    s.send_invoice("marcus", invoice)
    s.request_status("claire", sr, "closed")


def aldgate_ppm(s: Seeder):
    """Two working days ago: quarterly PPM at Aldgate House. Invoice still draft."""
    yield before(9, "11:00")
    job = s.new_job("marcus", "northgate", "aldgate", "Planned maintenance (PPM)",
                    "Q3 PPM — Aldgate House, level 4 and roof plant",
                    "Quarterly service to 4 × Toshiba cassettes (level 4) and 2 × roof condensers under contract "
                    "NPM-2024-117.", "normal", "cassette", "Level 4 cassettes 1–4; roof CU-1, CU-2",
                    "NPM-2024-117-Q3", before(2, "17:00").date())
    visit = s.book("marcus", job, "tom", before(2, "08:00"), before(2, "12:30"), phase="PPM service visit",
                   instructions="Permit to work for the roof from Dean at security. Filters are in the van order.")
    yield before(2, "07:52")
    s.on_my_way("tom", visit)
    yield before(2, "08:21")
    s.arrive("tom", visit, "aldgate")
    yield before(2, "12:04")
    s.tick("tom", job, "PPM service visit", range(7))
    s.labour("tom", job, visit, 3.5, 68)
    filters = s.part("tom", job, visit, "FILT-G4-592", 8, "material")
    cleaner = s.part("tom", job, visit, "COIL-CLEAN-5L", 1, "material")
    s.fgas("tom", visit, "R410A", "N/A — no gas added", 0, 0, "pass",
           "Direct leak test on both roof condensers, 12 kg charge each (25 t CO₂e). No leaks found.")
    yield before(2, "12:18")
    s.leave("tom", visit, "aldgate",
            "All 4 cassettes: filters replaced, coils and drip trays cleaned, condensate pumps tested. Roof "
            "CU-1/CU-2 coils washed, terminations checked. Cassette 3 fan bearing slightly noisy — monitor at next PPM.",
            3.5, signoff="Dean Wallace", complete_phase=True)
    yield before(2, "15:30")
    s.approve("marcus", filters, cleaner)
    s.job_status("marcus", job, "completed")
    yield before(1, "16:40")
    s.invoice("marcus", job, before(1, "16:40"), 30, "Quarterly PPM Q3 — contract NPM-2024-117")


def streatham_contactor(s: Seeder):
    """Yesterday: compressor tripping at FreshWay Streatham. Invoiced and sent."""
    logged = before(1, "07:38")
    yield logged
    sr = s.log_request("aisha", "freshway", "streatham", "Walk-in chiller compressor tripping",
                       "Store reports the walk-in dairy chiller compressor keeps tripping the breaker since opening; "
                       "cabinet at 7°C and rising.", "Tripping / electrical", "phone", "urgent",
                       "Deborah Okafor (store manager)", "coldroom", "CU-2 rear yard", 2, 8, logged)
    yield before(1, "07:45")
    job = s.convert("claire", sr, "Reactive breakdown", "streatham", "FW-PO-20931")
    visit = s.book("claire", job, "tom", before(1, "08:30"), before(1, "11:00"),
                   instructions="Store on 2-hour response. Yard key at the tills.")
    yield before(1, "08:02")
    s.on_my_way("tom", visit)
    yield before(1, "08:41")
    s.arrive("tom", visit, "streatham")
    s.tick("tom", job, "Diagnose", [0, 1, 2])
    yield before(1, "10:26")
    s.tick("tom", job, "Diagnose", [3, 4])
    s.tick("tom", job, "Repair & recommission", range(5))
    s.labour("tom", job, visit, 2, 85)
    contactor = s.part("tom", job, visit, "CONT-25A-230", 1)
    drier = s.part("tom", job, visit, "FD-DML-163", 1)
    s.fgas("tom", visit, "R448A", "DBS-R448A-0109", 0.8, 0, "pass",
           "System was 0.8 kg short after drier change. Leak tested with OFN at 20 bar — no leaks.")
    yield before(1, "10:40")
    s.leave("tom", visit, "streatham",
            "Compressor contactor contacts burnt, causing single-phasing and overload trips. Replaced contactor, "
            "fitted new filter drier, topped up 0.8 kg R448A. Cabinet down to 3°C within 35 minutes.",
            2, signoff="Deborah Okafor")
    s.phase_status("tom", job, "Diagnose", "completed")
    s.phase_status("tom", job, "Repair & recommission", "completed", signoff="Deborah Okafor")
    yield before(1, "13:15")
    s.approve("claire", contactor, drier)
    s.job_status("claire", job, "completed")
    s.request_status("claire", sr, "resolved", "Contactor and drier replaced.")
    yield before(0, "09:20")
    invoice = s.invoice("marcus", job, before(0, "09:20"), 30, "PO FW-PO-20931")
    s.send_invoice("marcus", invoice)
    s.request_status("claire", sr, "closed")


def towerbridge_installation(s: Seeder):
    """Installation in progress: survey done, first fix today, second fix booked."""
    yield before(12, "14:30")
    job = s.new_job("marcus", "northgate", "towerbridge", "Installation",
                    "Supply & install 3 × Mitsubishi PKA wall units — level 2 meeting rooms",
                    "Accepted quotation Q-NPM-7731: three PKA-M50KAL high-wall units with PUZ-ZM50 condensers on the "
                    "level 3 terrace, wired controllers, condensate pumps.", "normal", "pka",
                    "Meeting rooms 2.01, 2.02, 2.03", "Q-NPM-7731", ahead(3, "17:00").date(), estimated_hours=40)
    survey = s.book("marcus", job, "jake", before(10, "09:00"), before(10, "11:00"), phase="Site survey")
    yield before(10, "09:04")
    s.arrive("jake", survey, "towerbridge")
    yield before(10, "10:48")
    s.tick("jake", job, "Site survey", range(4))
    yield before(10, "10:52")
    s.leave("jake", survey, "towerbridge",
            "Unit positions agreed with Lucy Chen. 25 m pipe run to the terrace via the riser; spare 16 A way at DB2-3. "
            "RAMS issued.", 2, complete_phase=True)
    yield before(2, "14:00")
    first_fix = "Noisy works before 09:00 only. Scissor lift on site."
    jake_visit = s.book("marcus", job, "jake", before(0, "07:30"), before(0, "16:30"), phase="First fix",
                        instructions=first_fix)
    ryan_visit = s.book("marcus", job, "ryan", before(0, "07:30"), before(0, "16:30"), phase="First fix",
                        instructions=first_fix)
    s.book("marcus", job, "jake", ahead(0, "07:30"), ahead(0, "16:30"), phase="First fix")
    s.book("marcus", job, "ryan", ahead(0, "07:30"), ahead(0, "16:30"), phase="First fix")
    s.book("marcus", job, "jake", ahead(3, "07:30"), ahead(3, "16:30"), phase="Second fix & commissioning")
    lift = s.extra("marcus", job, "hire", "Genie GS-1932 scissor lift", 1, 145.00, supplier="Speedy Hire", days=5)
    yield before(0, "07:22")
    s.arrive("jake", jake_visit, "towerbridge")
    s.arrive("ryan", ryan_visit, "towerbridge")
    yield before(0, "16:12")
    s.tick("jake", job, "First fix", [0, 1, 2])
    s.labour("jake", job, jake_visit, 8.5, 72)
    s.labour("ryan", job, ryan_visit, 8.5, 45, "mate_nt")
    materials = [s.part("jake", job, jake_visit, "PIPE-CU-14", 27, "material"),
                 s.part("jake", job, jake_visit, "PIPE-CU-38", 27, "material"),
                 s.part("jake", job, jake_visit, "INS-ARMA-13", 54, "material"),
                 s.part("jake", job, jake_visit, "CABLE-4C-15", 30, "material")]
    yield before(0, "16:25")
    s.leave("jake", jake_visit, "towerbridge",
            "Brackets and sleeves fitted in all three rooms. Pipework brazed under nitrogen to the terrace for 2.01 "
            "and 2.02; 2.03 run half complete. Interconnects pulled. Condensate still to do.", 8.5)
    s.leave("ryan", ryan_visit, "towerbridge", "Assisted Jake with pipe runs and cable pulls.", 8.5)
    yield before(0, "16:50")
    s.approve("marcus", lift, *materials)


def riverside_vaccine_fridge(s: Seeder):
    """Today: vaccine fridge fan motor failed — part on order, job on hold, return visit booked."""
    logged = before(0, "07:32")
    yield logged
    sr = s.log_request("aisha", "riverside", "riverside", "Vaccine fridge reading 9°C",
                       "Duty nurse reports the treatment-room vaccine fridge alarmed overnight: 9.1°C, max 11.4°C. "
                       "Vaccines moved to the backup fridge.", "High temperature alarm", "phone", "urgent",
                       "Nurse Amy Clarke", "vaccine", "Fridge B — S/N 51.804.221.9", 2, 24, logged)
    yield before(0, "07:40")
    job = s.convert("claire", sr, "Reactive breakdown", "riverside", "RMP-2026-044")
    visit = s.book("claire", job, "tom", before(0, "08:00"), before(0, "10:00"), phase="Diagnose",
                   instructions="Vaccines already moved to Fridge A — do not move stock.")
    yield before(0, "07:48")
    s.on_my_way("tom", visit)
    yield before(0, "08:14")
    s.arrive("tom", visit, "riverside")
    yield before(0, "09:30")
    s.tick("tom", job, "Diagnose", range(5))
    s.labour("tom", job, visit, 1.75, 85)
    s.part("tom", job, visit, "FAN-LIE-6118010", 1)   # stays pending: the manager orders it in
    yield before(0, "09:58")
    s.leave("tom", visit, "riverside",
            "Condenser fan motor seized (0 rpm, winding open circuit). Compressor cycling on high-pressure cut-out. "
            "Cleaned condenser, fridge left OFF and labelled. Motor ordered from Beijer Ref Wimbledon — due Friday.",
            1.75, signoff="Sarah Collins", complete_phase=True,
            follow_up="Fit replacement fan motor 6118010 and run a 24 h temperature log before stock goes back in.")
    yield before(0, "10:25")
    s.job_status("claire", job, "on_hold", "Waiting for Liebherr fan motor — ETA Friday")
    s.book("claire", job, "sanjay", ahead(1, "08:00"), ahead(1, "09:30"), phase="Repair & recommission",
           instructions="Collect fan motor from Beijer Ref Wimbledon trade counter (order 771204).")


def croydon_door_heater(s: Seeder):
    """Today: freezer door heater replaced. Completed, waiting to be invoiced."""
    logged = before(1, "15:12")
    yield logged
    sr = s.log_request("aisha", "freshway", "croydon", "Freezer room door frozen shut",
                       "Ice build-up around the freezer room door, staff struggling to open it. Store thinks the door "
                       "heater has failed.", "Ice build-up", "email", "normal", "Imran Qureshi (store manager)",
                       "freezer", "Freezer room FR-1", 8, 48, logged)
    yield before(1, "15:40")
    job = s.convert("claire", sr, "Reactive breakdown", "croydon", "FW-PO-20944")
    visit = s.book("claire", job, "tom", before(0, "11:00"), before(0, "14:00"))
    yield before(0, "10:32")
    s.on_my_way("tom", visit)
    yield before(0, "11:09")
    s.arrive("tom", visit, "croydon")
    yield before(0, "13:40")
    s.tick("tom", job, "Diagnose", range(5))
    s.tick("tom", job, "Repair & recommission", [0, 3, 4])
    s.labour("tom", job, visit, 2.5, 85)
    heater = s.part("tom", job, visit, "HTR-DOOR-4M", 1)
    yield before(0, "13:55")
    s.leave("tom", visit, "croydon",
            "Door frame heater open circuit. Defrosted the frame, fitted a new 4 m heater cable and checked the "
            "RCD. Door seal in good condition. No refrigerant work.", 2.5, signoff="Imran Qureshi")
    s.phase_status("tom", job, "Diagnose", "completed")
    s.phase_status("tom", job, "Repair & recommission", "completed", signoff="Imran Qureshi", force=True,
                   notes="No refrigerant circuit work required.")
    yield before(0, "15:05")
    s.approve("claire", heater)
    s.job_status("claire", job, "completed")
    s.request_status("claire", sr, "resolved", "Door heater replaced.")


def kensington_vrf_ppm(s: Seeder):
    """Today: rooftop VRF PPM with F-Gas record. Completed; the manager hasn't invoiced yet."""
    yield before(8, "10:00")
    job = s.new_job("marcus", "kensington", "kensington", "Planned maintenance (PPM)",
                    "Quarterly PPM — rooftop VRF (2 × RXYSQ8TY1)",
                    "Quarterly maintenance of the rooftop VRF condensers and 18 guest-room fan coils (floors 4–5).",
                    "normal", "vrv", "CU-A S/N E002184, CU-B S/N E002191", "KGH-SLA-2026", before(0, "17:00").date())
    visit = s.book("marcus", job, "piotr", before(0, "09:00"), before(0, "13:30"), phase="PPM service visit",
                   instructions="Harness point by the roof hatch. Guest rooms 401–418 released 10:00–12:00.")
    yield before(0, "08:37")
    s.on_my_way("piotr", visit)
    yield before(0, "09:02")
    s.arrive("piotr", visit, "kensington")
    yield before(0, "13:05")
    s.tick("piotr", job, "PPM service visit", range(7))
    s.labour("piotr", job, visit, 4, 68)
    cleaner = s.part("piotr", job, visit, "COIL-CLEAN-5L", 1, "material")
    filters = s.part("piotr", job, visit, "FILT-G4-592", 4, "material")
    s.fgas("piotr", visit, "R410A", "N/A — no gas added", 0, 0, "pass",
           "Annual leak check: CU-A 18.4 kg, CU-B 17.9 kg (38.4 t / 37.4 t CO₂e). Electronic detector on all "
           "brazed joints and service valves — no leaks.")
    yield before(0, "13:24")
    s.leave("piotr", visit, "kensington",
            "Both VRF condensers washed and inspected, 18 fan coils filters cleaned (4 replaced), drain lines "
            "flushed on 407 and 412. Room 412 fan coil return air sensor reading 3 K high — recommend replacement.",
            4, signoff="Andrew Blake", complete_phase=True,
            follow_up="Quote: replace return air thermistor on room 412 fan coil.")
    yield before(0, "16:02")
    s.approve("marcus", cleaner, filters)
    s.job_status("marcus", job, "completed")


def whitfield_no_access(s: Seeder):
    """Today: domestic heat pump service — nobody home. Needs rebooking."""
    yield before(11, "12:10")
    sr = s.log_request("aisha", "whitfield", "whitfield", "Annual heat pump service",
                       "Customer booked the annual Ecodan service through the website. Prefers mornings.",
                       "Planned maintenance", "portal", "low", "James Whitfield", "ecodan", "S/N 23X04418")
    yield before(11, "12:30")
    job = s.convert("marcus", sr, "Planned maintenance (PPM)", "whitfield", None)
    visit = s.book("marcus", job, "sanjay", before(0, "09:30"), before(0, "11:00"),
                   instructions="Customer asked for a call 30 minutes before arrival.")
    yield before(0, "09:02")
    s.on_my_way("sanjay", visit)
    yield before(0, "09:41")
    s.no_access("sanjay", visit,
                "No answer at the door. Called the customer twice and left a voicemail; waited 20 minutes. "
                "Side gate locked.")


def olive_richmond_ppm(s: Seeder):
    """Today: restaurant PPM completed by Sanjay after the no-access."""
    yield before(6, "09:00")
    job = s.new_job("marcus", "olive", "olive_rich", "Planned maintenance (PPM)",
                    "Six-monthly PPM — dining room ducted AC and kitchen refrigeration",
                    "2 × Daikin FBA71A ducted units, cold room and 3 reach-in fridges.", "normal", "ducted",
                    None, "OT-PPM-H2", before(0, "17:00").date())
    visit = s.book("marcus", job, "sanjay", before(0, "11:30"), before(0, "14:00"), phase="PPM service visit",
                   instructions="Kitchen closes 15:00–17:30; dining room AC can be isolated before 12:00.")
    yield before(0, "11:12")
    s.arrive("sanjay", visit, "olive_rich")
    yield before(0, "14:10")
    s.tick("sanjay", job, "PPM service visit", range(7))
    s.labour("sanjay", job, visit, 2.75, 68)
    pump = s.part("sanjay", job, visit, "PUMP-ASPEN-MO", 1)
    yield before(0, "14:22")
    s.leave("sanjay", visit, "olive_rich",
            "PPM complete. Ducted unit 2 condensate pump failing (intermittent float) — replaced with Aspen Mini "
            "Orange. Cold room door gasket torn at the hinge side: recommend replacement.",
            2.75, signoff="Hannah Price", complete_phase=True,
            follow_up="Quote for a new cold room door gasket (1.9 × 0.8 m).")


def olive_cg_emergency(s: Seeder):
    """Right now: out-of-hours cold room emergency — Tom is on site."""
    logged = ago(96)
    yield logged
    manager = "claire" if OUT_OF_HOURS else "aisha"
    sr = s.log_request(manager, "olive", "olive_cg", "Cold room at 11°C during service",
                       "Head chef Luca: kitchen cold room alarm, 11°C and rising, full of stock for tonight's "
                       "service. Condensing unit running but not cooling.", "High temperature alarm", "phone",
                       "urgent", "Luca Romano (head chef)", "coldroom", "CR-1 — S/N 2019-11-04873", 1, 4, logged)
    yield ago(90)
    job_type = "Emergency call-out" if OUT_OF_HOURS else "Reactive breakdown"
    job = s.convert("claire", sr, job_type, "olive_cg", "OT-CG-EM-0916")
    phase = "Emergency attendance" if OUT_OF_HOURS else "Diagnose"
    visit = s.book("claire", job, "tom", ago(88), ago(-60), phase=phase,
                   instructions="Luca is expecting you — rear door on Exchange Court. Stock is at risk.")
    yield ago(84)
    s.on_my_way("tom", visit)
    yield ago(38)
    s.arrive("tom", visit, "olive_cg")
    yield ago(22)
    s.tick("tom", job, phase, [0, 1])
    yield ago(9)
    s.part("tom", job, visit, "REF-R448A-KG", 3.2)
    s.part("tom", job, visit, "FD-DML-163", 1)
    s.fgas("tom", visit, "R448A", "DBS-R448A-0117", 3.2, 0, "fail",
           "Leak found on the flare joint at the TXV (bubbles at 18 bar). Joint remade, retested with OFN — holding. "
           "Follow-up leak check due within 28 days.")


def streatham_multideck(s: Seeder):
    """Right now: Kwame on site with a warm dairy multideck."""
    logged = ago(170)
    yield logged
    sr = s.log_request("aisha" if not OUT_OF_HOURS else "claire", "freshway", "streatham",
                       "Dairy multideck at 8°C", "Store manager reports the dairy multideck by the tills is at 8°C "
                       "and rising; milk moved to the walk-in.", "High temperature alarm", "phone", "urgent",
                       "Deborah Okafor (store manager)", "multideck", "MD-3 — S/N 0918-37511", 2, 8, logged)
    yield ago(160)
    job = s.convert("claire", sr, "Reactive breakdown", "streatham", "FW-PO-20958")
    visit = s.book("claire", job, "kwame", ago(150), ago(-30), phase="Diagnose")
    yield ago(118)
    s.on_my_way("kwame", visit)
    yield ago(52)
    s.arrive("kwame", visit, "streatham")
    yield ago(30)
    s.tick("kwame", job, "Diagnose", [0, 1, 2])


def brightwell_crac_alarm(s: Seeder):
    """Booked for the next working day: CRAC head-pressure alarm (portal ticket)."""
    logged = before(0, "15:48")
    yield logged
    sr = s.log_request("aisha", "brightwell", "brightwell", "CRAC 3 high head pressure alarms",
                       "Portal ticket BW-INC-40588: CRAC 3 in data hall 2 has logged four high head pressure alarms "
                       "since 06:00; unit auto-resets. Supply air stable at 22°C.", "Alarm / fault code", "portal",
                       "high", "Priya Shah (critical facilities manager)", "crac", "CRAC 3 — S/N 1911-PX025-0447",
                       4, 48, logged)
    yield before(0, "16:05")
    job = s.convert("claire", sr, "Reactive breakdown", "brightwell", "BW-PO-119207")
    s.book("claire", job, "tom", ahead(0, "08:30"), ahead(0, "11:00"), phase="Diagnose",
           instructions="Access booked on the portal for 08:15 (ref ACC-55120). Bring ID. Escort from the NOC.")


def oakfield_server_room(s: Seeder):
    """Booked for the next working day after school drop-off, plus yesterday's missed filter visit (overdue)."""
    logged = before(0, "12:26")
    yield logged
    sr = s.log_request("aisha", "oakfield", "oakfield", "Server room AC not cooling — 27°C",
                       "School business manager reports the server cupboard is at 27°C and the wall unit is blowing "
                       "warm air. IT have opened the door and put a fan in.", "No cooling", "phone", "high",
                       "Janet Holloway (school business manager)", "fujitsu", "S/N T0A 004712", 4, 24, logged)
    yield before(0, "12:50")
    job = s.convert("claire", sr, "Reactive breakdown", "oakfield", "OPS-PO-3318")
    s.book("claire", job, "tom", ahead(0, "13:00"), ahead(0, "15:00"), phase="Diagnose",
           instructions="Sign in at the office. Server cupboard is next to the staff room.")


def oakfield_missed_ppm(s: Seeder):
    """A PPM visit left open from a previous day — shows as overdue for Sanjay."""
    yield before(9, "09:30")
    job = s.new_job("marcus", "oakfield", "oakfield", "Planned maintenance (PPM)",
                    "Autumn term PPM — ICT suite split units",
                    "Filter clean and service of 4 × wall splits in the ICT suite before the heating season.",
                    "low", "fujitsu", None, "OPS-PPM-AUT", before(1, "17:00").date())
    s.book("marcus", job, "sanjay", before(1, "15:45"), before(1, "17:15"), phase="PPM service visit",
           instructions="After 15:30 only (term time).")


def brightwell_chiller_leak_check(s: Seeder):
    """Statutory leak check booked later in the week."""
    yield before(5, "11:15")
    job = s.new_job("marcus", "brightwell", "brightwell", "F-Gas leak check",
                    "Six-monthly F-Gas leak check — chiller CH-1", "Carrier 30RB-0262R, 2 circuits, 64 kg R410A "
                    "(133.6 t CO₂e): six-monthly check (automatic leak detection fitted).", "normal", "chiller",
                    "CH-1 — S/N 2203-30RB-11087", "BW-PPM-FGAS", ahead(2, "17:00").date())
    s.book("marcus", job, "piotr", ahead(2, "09:00"), ahead(2, "12:00"), phase="Leak check",
           instructions="Book access on the portal 48 h ahead. Leak detection system test with the NOC.")


def croydon_ppm(s: Seeder):
    yield before(4, "10:05")
    job = s.new_job("marcus", "freshway", "croydon", "Planned maintenance (PPM)",
                    "Quarterly refrigeration PPM — Store 087",
                    "Freezer room, 2 × multidecks, 4 × condensing units.", "normal", "freezer", None,
                    "FW-PPM-087-Q3", ahead(4, "17:00").date())
    s.book("marcus", job, "kwame", ahead(4, "06:30"), ahead(4, "10:30"), phase="PPM service visit",
           instructions="Before store opening if possible.")


def aldgate_cassette_quote(s: Seeder):
    """Quotation stage: replacing two old R22 cassettes. Draft job with priced quote-sheet lines."""
    logged = before(3, "11:47")
    yield logged
    sr = s.log_request("aisha", "northgate", "aldgate", "Quote: replace 2 × R22 cassettes on level 5",
                       "Helen Marsh asks for a quotation to replace the two remaining R22 ceiling cassettes on level 5 "
                       "(tenant fit-out in November).", "Quotation request", "email", "normal",
                       "Helen Marsh (facilities manager)", "cassette", "Level 5 — C5-1, C5-2", None, None, logged)
    yield before(2, "10:15")
    job = s.convert("marcus", sr, "Installation", "aldgate", "NPM-Q-7802",
                    title="Replace 2 × R22 cassettes with R32 units — level 5")
    for description, quantity, price in [("Toshiba RAV-RM1101UTP-E cassette + RAV-GM1101ATP-E condenser", 2, 3240.00),
                                         ("Wired controller RBC-AMS55E-ES", 2, 138.00)]:
        s.extra("marcus", job, "material", description, quantity, price, supplier="Toshiba Air Conditioning")
    s.extra("marcus", job, "labour", "Engineer — normal time (strip out, install, commission)", 24, 72)
    s.extra("marcus", job, "labour", "Mate — normal time", 16, 45)
    s.extra("marcus", job, "expense", "R22 recovery and waste transfer note", 1, 180.00)
    s.extra("marcus", job, "hire", "Genie GS-1932 scissor lift", 1, 145.00, supplier="Speedy Hire", days=3)
    s.request_status("marcus", sr, "on_hold", "Quotation sent to Helen Marsh — awaiting PO.")


def richmond_extract_fan(s: Seeder):
    """Triaged, not yet booked."""
    logged = before(1, "14:03")
    yield logged
    noisy = s.log_request("aisha", "olive", "olive_rich", "Kitchen extract fan grinding noise",
                          "Grinding noise from the kitchen extract fan, worse on high speed.", "Noisy operation",
                          "phone", "low", "Hannah Price (general manager)", None, None, 24, 120, logged)
    yield before(1, "14:20")
    s.request_status("claire", noisy, "triaged", None)


def aldgate_reception_leak(s: Seeder):
    """New this afternoon, not yet looked at."""
    logged = before(0, "16:42")
    yield logged
    s.log_request("aisha", "northgate", "aldgate", "Water dripping from cassette in reception",
                  "Security reports water dripping from the ceiling cassette above the reception desk; bucket in "
                  "place.", "Water leak", "email", "normal", "Dean Wallace (security desk)", "cassette",
                  "Ground floor reception", 4, 48, logged)


def kensington_room_412(s: Seeder):
    """Guest complaint this evening — its response SLA has already been missed."""
    logged = ago(64)
    yield logged
    s.log_request("claire" if OUT_OF_HOURS else "aisha", "kensington", "kensington",
                  "Room 412 — guest says air con blowing warm",
                  "Night manager: guest in 412 complaining the room is 26°C with the AC on cool. Offered a room move, "
                  "guest declined.", "No cooling", "phone", "high", "Sofia Marin (night manager)", "vrv",
                  "Fan coil FCU-412", 0.75, 24, logged)


def olive_cg_duplicate_alarm(s: Seeder):
    """The alarm company's ticket for the same cold room, closed as a duplicate once Tom is sent."""
    logged = ago(101)
    yield logged
    dup = s.log_request("aisha", "olive", "olive_cg", "Cold room alarm — Covent Garden",
                        "Alarm company auto-alert for kitchen cold room high temperature.", "High temperature alarm",
                        "email", "high", "RedCare alarm centre", "coldroom", None, 1, 4, logged)
    yield ago(79)
    s.request_status("claire", dup, "duplicate", "Same fault as the call from Luca — already attending.")


STORIES = [
    brightwell_humidifier, olive_richmond_ice_machine, aldgate_ppm, streatham_contactor, towerbridge_installation,
    riverside_vaccine_fridge, croydon_door_heater, kensington_vrf_ppm, whitfield_no_access, olive_richmond_ppm,
    olive_cg_emergency, streatham_multideck, brightwell_crac_alarm, oakfield_server_room, oakfield_missed_ppm,
    brightwell_chiller_leak_check, croydon_ppm, aldgate_cassette_quote, richmond_extract_fan,
    aldgate_reception_leak, kensington_room_412, olive_cg_duplicate_alarm,
]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--reset", action="store_true",
                        help="delete DBS Limited's requests, jobs, visits and invoices and rebuild them around now")
    args = parser.parse_args()

    if DB in ("opsapi-diytaxreturn",) or "prod" in DB:
        die(f"refusing to seed database '{DB}'")
    if not FS_ENV.exists():
        die("run scripts/local-opsapi-fs-seed.sh first (it creates the isolated stack's test password)")
    env = dict(line.split("=", 1) for line in FS_ENV.read_text().splitlines() if "=" in line and not line.startswith("#"))
    otp = subprocess.run(["docker", "exec", API_CONTAINER, "printenv", "TEST_OTP_CODE"],
                         capture_output=True, text=True).stdout.strip()
    if not otp:
        die(f"TEST_OTP_CODE is not set in {API_CONTAINER}")

    s = Seeder(env["WSL_PASSWORD"], otp)
    setup_reference_data(s)

    existing = int(sql_value(f"SELECT COUNT(*) FROM fs_jobs WHERE namespace_id = {s.ns_id}") or 0)
    if existing and not args.reset:
        die(f"DBS Limited already has {existing} jobs. Re-run with --reset to rebuild the day around now.")
    print("7. Work: requests, jobs, visits, quotes and invoices" + (" (reset)" if existing else ""))
    reset_work(s)
    set_sequences(s)
    print(f"   round {ROUND:%a %d %b}, next {NEXT:%a %d %b}, {'out of hours' if OUT_OF_HOURS else 'working hours'}")
    s.run(story(s) for story in STORIES)
    # Older notifications have been read; today's are still new.
    sql(f"UPDATE notifications SET is_read = true WHERE type LIKE 'fs_%' AND created_at < NOW() - interval '20 hours' "
        f"AND user_id IN (SELECT user_id FROM namespace_members WHERE namespace_id = {s.ns_id})")

    OUT.parent.mkdir(exist_ok=True)
    OUT.write_text("\n".join([
        "# DBS Limited local test workspace — generated by scripts/seed-dbs-limited.py. Do not commit.",
        f"WSL_API={API}", f"WSL_NAMESPACE={s.ns_uuid}", f"WSL_PASSWORD={s.password}", f"WSL_OTP={otp}",
        *[f"DBS_{key.upper()}={username}" for key, _, _, username, _ in STAFF],
    ]) + "\n")
    OUT.chmod(0o600)

    counts = sql(f"""SELECT
        (SELECT COUNT(*) FROM fs_service_requests WHERE namespace_id = {s.ns_id}),
        (SELECT COUNT(*) FROM fs_jobs WHERE namespace_id = {s.ns_id}),
        (SELECT COUNT(*) FROM fs_visits WHERE namespace_id = {s.ns_id}),
        (SELECT COUNT(*) FROM fs_job_items WHERE namespace_id = {s.ns_id}),
        (SELECT COUNT(*) FROM invoices WHERE namespace_id = {s.ns_id})""")[0]
    print(f"Done. DBS Limited ({s.ns_uuid}): {counts[0]} requests, {counts[1]} jobs, {counts[2]} visits, "
          f"{counts[3]} quote-sheet lines, {counts[4]} invoices.")
    print("Sign in as tom.fletcher (engineer), claire.donnelly / marcus.reid (service managers) or aisha.rahman "
          "(service desk); password and OTP are in build/dbs-limited.env (not printed).")


if __name__ == "__main__":
    try:
        main()
    except APIFailure as failure:
        die(str(failure))
