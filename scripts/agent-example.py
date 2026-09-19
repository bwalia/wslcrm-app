#!/usr/bin/env python3
"""A minimal agent that works one card, the way docs/AGENTS.md says to.

It finds an agent-ready card, claims it with a short lease, heartbeats while it "works", writes a
result and moves the card to the review column for a person to decide on. The work itself is
deliberately trivial — the point is the protocol around it, and what it looks like in the app
while it happens.

    scripts/agent-example.py --env build/dbs-group-demo.env --user DBS_TOM
    scripts/agent-example.py --env build/dbs-group-demo.env --api-key opsk_...   # once keys can be members
    scripts/agent-example.py --env … --project <uuid> --dry-run

Run it with the iOS app open on the same board: the claim, the heartbeat and the result appear on
the card as they are written, which is the collision this whole design exists to handle.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timedelta, timezone

LEASE_SECONDS = 600
HEARTBEAT_SECONDS = 60


def utc(moment: datetime) -> str:
    """The naive-UTC format the whole API speaks."""
    return moment.astimezone(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")


def parse_utc(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.strptime(value[:19], "%Y-%m-%d %H:%M:%S").replace(tzinfo=timezone.utc)
    except ValueError:
        return None


class Client:
    def __init__(self, base: str, token: str, namespace: str | None):
        self.base = base.rstrip("/")
        self.token = token
        self.namespace = namespace

    def call(self, method: str, path: str, body=None, ok=(200, 201)):
        data = json.dumps(body).encode() if body is not None else None
        headers = {"Accept": "application/json", "Authorization": f"Bearer {self.token}"}
        if data:
            headers["Content-Type"] = "application/json"
        if self.namespace:
            headers["X-Namespace-Id"] = self.namespace
        request = urllib.request.Request(self.base + path, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                raw = response.read()
                payload = json.loads(raw) if raw else {}
        except urllib.error.HTTPError as error:
            raw = error.read().decode(errors="replace")
            if error.code == 403 and "/kanban/" in path:
                sys.exit(
                    f"403 on {path}.\n"
                    "If this is an API key: a key principal is not a users row, and kanban checks\n"
                    "project membership by user uuid — run as a bot user until that is fixed\n"
                    "server-side (see docs/AGENTS.md §1)."
                )
            sys.exit(f"{method} {path} -> {error.code}: {raw[:400]}")
        if isinstance(payload, dict) and "data" in payload:
            return payload["data"]
        return payload


def sign_in(base: str, identifier: str, password: str, otp: str) -> str:
    """The same two-step sign-in a person does; int accepts the seeded bypass code."""
    form = urllib.parse.urlencode({"identifier": identifier, "password": password}).encode()
    request = urllib.request.Request(
        base.rstrip("/") + "/auth/login", data=form, method="POST",
        headers={"Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"})
    with urllib.request.urlopen(request, timeout=60) as response:
        started = json.loads(response.read())
    verify = json.dumps({"session_token": started["session_token"], "code": otp}).encode()
    request = urllib.request.Request(
        base.rstrip("/") + "/auth/2fa/verify", data=verify, method="POST",
        headers={"Content-Type": "application/json", "Accept": "application/json"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.loads(response.read())["token"]


def contract_of(task: dict) -> dict:
    return (task.get("metadata") or {}).get("agent") or {}


def is_eligible(task: dict) -> bool:
    """A card without a goal, acceptance and a definition of done is not work, it is a wish."""
    agent = contract_of(task)
    return bool(agent.get("goal") and agent.get("acceptance") and agent.get("definition_of_done"))


def claim_is_someone_elses(task: dict, me: str) -> bool:
    claim = contract_of(task).get("claim") or {}
    if not claim.get("by") or claim["by"] == me:
        return False
    expires = parse_utc(claim.get("expires_at"))
    return expires is None or expires > datetime.now(timezone.utc)


def write_contract(client: Client, task: dict, changes: dict) -> dict:
    """Read-modify-write that keeps every other key in the blob, and refuses a clobber."""
    latest = client.call("GET", f"/api/v2/kanban/tasks/{task['uuid']}")
    if latest.get("updated_at") != task.get("updated_at"):
        sys.exit("the card changed under us — re-read it rather than overwriting somebody's edit")
    metadata = latest.get("metadata") or {}
    agent = dict(metadata.get("agent") or {})
    agent.update(changes)
    metadata["agent"] = agent
    return client.call("PUT", f"/api/v2/kanban/tasks/{task['uuid']}", {"metadata": metadata})


def comment(client: Client, task_uuid: str, text: str, key: str) -> None:
    """Idempotent by convention: the marker lets a retry recognise its own write."""
    existing = client.call("GET", f"/api/v2/kanban/tasks/{task_uuid}/comments") or []
    if any(key in (row.get("content") or "") for row in existing):
        return
    client.call("POST", f"/api/v2/kanban/tasks/{task_uuid}/comments",
                {"content": f"{text}\n\n<!-- idem:{key} -->"})


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--env", default="build/dbs-group-demo.env", help="env file with the seeded accounts")
    parser.add_argument("--user", default="DBS_TOM", help="which account in that file to sign in as")
    parser.add_argument("--api-key", help="an opsk_… key instead of signing in")
    parser.add_argument("--project", help="project uuid (default: the first one you are a member of)")
    parser.add_argument("--review-column", default="Needs review", help="where finished work goes")
    parser.add_argument("--dry-run", action="store_true", help="find a card and stop")
    arguments = parser.parse_args()

    env = {}
    if os.path.exists(arguments.env):
        for line in open(arguments.env):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                env[key] = value.strip().strip("'\"")
    base = env.get("WSL_API", "https://int-opsapi.workstation.co.uk")

    if arguments.api_key:
        token, me, my_name = arguments.api_key, None, "api-key"
    else:
        token = sign_in(base, env[arguments.user], env["WSL_PASSWORD"], env["WSL_OTP"])
        token_body = json.loads(__import__("base64").urlsafe_b64decode(
            token.split(".")[1] + "=" * (-len(token.split(".")[1]) % 4)))
        user = token_body.get("userinfo", {})
        me, my_name = user.get("uuid"), user.get("username") or arguments.user
    client = Client(base, token, env.get("WSL_NAMESPACE"))

    projects = client.call("GET", "/api/v2/kanban/projects?perPage=50") or []
    if not projects:
        sys.exit("no projects — an agent only sees projects it is a member of")
    project = next((p for p in projects if p["uuid"] == arguments.project), projects[0])
    print(f"project: {project['name']}")

    boards = client.call("GET", f"/api/v2/kanban/projects/{project['uuid']}/boards") or []
    if not boards:
        sys.exit("no boards on that project")
    board = client.call("GET", f"/api/v2/kanban/boards/{boards[0]['uuid']}/full")
    columns = board.get("columns") or []
    review_column = next((c for c in columns if c["name"].lower() == arguments.review_column.lower()),
                         columns[-1] if columns else None)

    candidates = [task for column in columns for task in (column.get("tasks") or [])
                  if is_eligible(task) and not claim_is_someone_elses(task, me)]
    if not candidates:
        print("nothing to pick up: no card has a goal, acceptance and a definition of done "
              "that isn't already claimed")
        return
    task = candidates[0]
    agent = contract_of(task)
    print(f"card: #{task.get('task_number')} {task['title']}")
    print(f"goal: {agent['goal']}")
    if arguments.dry_run:
        return

    run_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc)
    task = write_contract(client, task, {
        "claim": {"by": me, "kind": "agent", "name": my_name,
                  "at": utc(now), "expires_at": utc(now + timedelta(seconds=LEASE_SECONDS))},
        "run": {"id": run_id, "attempt": (agent.get("run") or {}).get("attempt", 1),
                "started_at": utc(now), "heartbeat_at": utc(now)},
        "result": {"status": "running"},
    })

    # Confirm the claim is ours before doing anything: somebody may have claimed it in the gap.
    task = client.call("GET", f"/api/v2/kanban/tasks/{task['uuid']}")
    if (contract_of(task).get("claim") or {}).get("by") != me:
        sys.exit("lost the race for this card — backing off")
    print("claimed. working…")

    # The "work": two heartbeats' worth, checking whether a person has asked us to stop.
    budget = (agent.get("budget") or {}).get("minutes")
    started = time.monotonic()
    for _ in range(2):
        time.sleep(3)
        task = client.call("GET", f"/api/v2/kanban/tasks/{task['uuid']}")
        if contract_of(task).get("stop_requested"):
            write_contract(client, task, {"result": {"status": "failed", "summary": "Stopped on request."}})
            print("a person asked us to stop — card put down")
            return
        spent = int((time.monotonic() - started) / 60)
        if budget and spent > budget:
            write_contract(client, task, {"result": {"status": "failed", "summary": "Out of budget."}})
            print("out of budget — card put down")
            return
        task = write_contract(client, task, {
            "run": {**(contract_of(task).get("run") or {}), "heartbeat_at": utc(datetime.now(timezone.utc)),
                    "cost": {"minutes": spent}},
        })

    summary = (f"Checked {len(agent.get('acceptance', []))} acceptance criteria against the data "
               f"and prepared the output.")
    write_contract(client, task, {
        "result": {"status": "needs_review", "summary": summary,
                   "artifacts": [{"name": "example-output.txt", "kind": "text"}],
                   "finished_at": utc(datetime.now(timezone.utc))},
    })
    comment(client, task["uuid"], f"{my_name}: {summary}", run_id)
    if review_column:
        client.call("PUT", f"/api/v2/kanban/tasks/{task['uuid']}/move",
                    {"column_id": review_column["id"]})   # numeric id, not a uuid
        print(f"moved to {review_column['name']} for review")
    print("done — a person decides from here")


if __name__ == "__main__":
    main()
