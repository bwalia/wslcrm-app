#!/usr/bin/env bash
# Seed a LOCAL OPSAPI (Docker) with a Field Service test tenant for Simulator testing.
#
# Creates (idempotently) in the given local database:
#   - a non-admin owner, and via the API: namespace "FS Test" (field-service roles auto-seeded),
#     service manager, telecaller and engineer users
#   - a store + one store product (the serviced unit / asset) and a customer
# and writes build/local-fs-test.env (git-ignored, mode 600) for the Local UI test.
#
# Never run this against a shared or production database. Defaults target the isolated
# PR #610 stack described in README ("Local OPSAPI for Simulator testing").
set -euo pipefail

API="${API:-http://127.0.0.1:4011}"
API_CONTAINER="${API_CONTAINER:-wslcrm-opsapi-pr610}"
PG_CONTAINER="${PG_CONTAINER:-opsapi-postgres-dev-db}"
DB="${DB:-opsapi-wslcrm-pr610}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/local-fs-test.env"

case "$DB" in opsapi-diytaxreturn|*prod*) echo "Refusing to seed database '$DB'." >&2; exit 1 ;; esac

mkdir -p "$ROOT/build"
umask 077
if [ -f "$OUT" ] && grep -q '^WSL_PASSWORD=' "$OUT"; then
  FS_PW="$(grep '^WSL_PASSWORD=' "$OUT" | cut -d= -f2-)"
else
  # >=12 chars with upper, lower and digit (helper/validations.lua); random, so not in HIBP.
  FS_PW="Fs$(openssl rand -hex 10)Aa9"
fi
OTP="$(docker exec "$API_CONTAINER" printenv TEST_OTP_CODE)"
[ -n "$OTP" ] || { echo "TEST_OTP_CODE is not set in $API_CONTAINER" >&2; exit 1; }

pgq() { docker exec -i "$PG_CONTAINER" sh -c "psql -U \"\$POSTGRES_USER\" -d '$DB' -v ON_ERROR_STOP=1 -Atq" ; }

login() { # $1 identifier -> JWT
  local st
  st=$(curl -sf -X POST "$API/auth/login" -H 'Content-Type: application/x-www-form-urlencoded' \
        --data-urlencode "identifier=$1" --data-urlencode "password=$FS_PW" | jq -r .session_token)
  curl -sf -X POST "$API/auth/2fa/verify" -H 'Content-Type: application/json' \
       -d "$(jq -nc --arg s "$st" --arg c "$OTP" '{session_token:$s, code:$c}')" | jq -r .token
}

api() { # $1 token, rest curl args
  local tok=$1; shift
  curl -s -H "Authorization: Bearer $tok" -H "X-Namespace-Id: ${NS:-}" -H 'Content-Type: application/json' "$@"
}

echo "1. Owner (SQL bootstrap; login ignores platform roles — this user is NOT an admin)"
printf '%s\n' "INSERT INTO users (uuid, first_name, last_name, email, username, password, active, created_at, updated_at)
  SELECT gen_random_uuid()::text, 'FS', 'Owner', 'fs-owner@e2e.invalid', 'fs_owner', crypt('$FS_PW', gen_salt('bf', 10)), true, NOW(), NOW()
  WHERE NOT EXISTS (SELECT 1 FROM users WHERE email = 'fs-owner@e2e.invalid');
  UPDATE users SET password = crypt('$FS_PW', gen_salt('bf', 10)), active = true WHERE email = 'fs-owner@e2e.invalid';" | pgq
OWNER=$(login fs-owner@e2e.invalid)

echo "2. Namespace 'FS Test'"
NS=$(echo "SELECT uuid FROM namespaces WHERE slug = 'fs-test'" | pgq)
if [ -z "$NS" ]; then
  NS=$(curl -s -X POST "$API/api/v2/user/namespaces" -H "Authorization: Bearer $OWNER" -H 'Content-Type: application/json' \
        -d '{"name":"FS Test","slug":"fs-test","description":"Local Field Service test tenant"}' | jq -r '.namespace.uuid // .data.uuid')
fi
[ -n "$NS" ] && [ "$NS" != "null" ] || { echo "Could not create namespace" >&2; exit 1; }
# Undo the resolver's auto-join of a brand-new user into the System namespace.
curl -s -X PUT "$API/api/v2/user/namespace-settings" -H "Authorization: Bearer $OWNER" -H 'Content-Type: application/json' \
  -d "{\"default_namespace_id\":\"$NS\"}" >/dev/null
SYSTEM_NS=$(echo "SELECT uuid FROM namespaces WHERE slug = 'system'" | pgq)
[ -n "$SYSTEM_NS" ] && curl -s -X POST "$API/api/v2/namespace/leave" -H "Authorization: Bearer $OWNER" -H "X-Namespace-Id: $SYSTEM_NS" >/dev/null || true

echo "3. Manager, telecaller, engineer"
mk() { # email username first last role
  if [ -z "$(echo "SELECT 1 FROM users WHERE email = '$1'" | pgq)" ]; then
    api "$OWNER" -X POST "$API/api/v2/users" \
      -d "$(jq -nc --arg e "$1" --arg u "$2" --arg p "$FS_PW" --arg f "$3" --arg l "$4" --arg r "$5" \
            '{email:$e, username:$u, password:$p, first_name:$f, last_name:$l, namespace_role:$r}')" \
      | jq -c '{email: (.data.email // .email), error: .error}'
  fi
}
mk fs-manager@e2e.invalid    fs_manager    Sam   Manager  service_manager
mk fs-telecaller@e2e.invalid fs_telecaller Tara  Caller   telecaller
mk fs-engineer@e2e.invalid   fs_engineer   Eddie Engineer engineer
# PUT /api/v2/users is broken (writes a missing updated_by column), so activation is SQL.
echo "UPDATE users SET active = true, updated_at = NOW() WHERE email LIKE 'fs-%@e2e.invalid'" | pgq

echo "4. Store (SQL — POST /api/v2/stores writes a missing created_by column) and serviced unit"
printf '%s\n' "INSERT INTO stores (uuid, user_id, namespace_id, name, slug, status, currency, tax_rate, created_at, updated_at)
  SELECT gen_random_uuid()::text, u.id, n.id, 'FS Test Units', 'fs-test-units', 'active', 'GBP', 0.2, NOW(), NOW()
  FROM users u, namespaces n WHERE u.email = 'fs-owner@e2e.invalid' AND n.slug = 'fs-test'
  AND NOT EXISTS (SELECT 1 FROM stores WHERE slug = 'fs-test-units');" | pgq
STORE=$(echo "SELECT uuid FROM stores WHERE slug = 'fs-test-units'" | pgq)
PRODUCT=$(echo "SELECT p.uuid FROM storeproducts p JOIN stores s ON s.id = p.store_id WHERE s.slug = 'fs-test-units' AND p.sku = 'FS-TEST-AC-001'" | pgq)
if [ -z "$PRODUCT" ]; then
  PRODUCT=$(api "$OWNER" -X POST "$API/api/v2/products" \
    -d "{\"store_id\":\"$STORE\",\"name\":\"Daikin FTXM35R split AC\",\"sku\":\"FS-TEST-AC-001\",\"price\":1,\"compare_price\":1,\"description\":\"Wall-mounted split air conditioner\",\"track_inventory\":false}" \
    | jq -r .data.uuid)
fi

echo "5. Customer"
CUSTOMER=$(echo "SELECT c.uuid FROM customers c JOIN namespaces n ON n.id = c.namespace_id WHERE n.slug = 'fs-test' ORDER BY c.id LIMIT 1" | pgq)
if [ -z "$CUSTOMER" ]; then
  MGR=$(login fs-manager@e2e.invalid)
  CUSTOMER=$(api "$MGR" -X POST "$API/api/v2/customers" \
    -d "{\"email\":\"fs-customer-$(date +%s)@e2e.invalid\",\"first_name\":\"Priya\",\"last_name\":\"Patel\",\"phone\":\"+447700900001\"}" \
    | jq -r .data.uuid)
fi

echo "6. Job type with a rate + phase templates (so jobs get checklist phases and can be invoiced)"
MGR=${MGR:-$(login fs-manager@e2e.invalid)}
JOB_TYPE=$(api "$MGR" "$API/api/v2/field-service/job-types?include_inactive=true" | jq -r '.data[] | select(.name == "AC repair") | .uuid' | head -1)
if [ -z "$JOB_TYPE" ]; then
  JOB_TYPE=$(api "$MGR" -X POST "$API/api/v2/field-service/job-types" \
    -d '{"name":"AC repair","description":"Diagnose and repair an air conditioning unit","default_hourly_rate":65,"color":"#0ea5e9"}' | jq -r .data.uuid)
  api "$MGR" -X POST "$API/api/v2/field-service/job-types/$JOB_TYPE/phases" \
    -d '{"name":"Diagnose","requires_visit":true,"estimated_hours":1,"checklist":["Isolate power","Check refrigerant pressure"]}' >/dev/null
  api "$MGR" -X POST "$API/api/v2/field-service/job-types/$JOB_TYPE/phases" \
    -d '{"name":"Repair & test","requires_visit":true,"estimated_hours":2,"checklist":["Replace faulty part","Run system test"]}' >/dev/null
fi

cat > "$OUT" <<EOF
# Local OPSAPI Field Service test tenant — generated by scripts/local-opsapi-fs-seed.sh. Do not commit.
WSL_API=$API
WSL_NAMESPACE=$NS
WSL_PASSWORD=$FS_PW
WSL_OTP=$OTP
WSL_OWNER=fs-owner@e2e.invalid
WSL_MANAGER=fs-manager@e2e.invalid
WSL_TELECALLER=fs-telecaller@e2e.invalid
WSL_ENGINEER=fs-engineer@e2e.invalid
WSL_PRODUCT_UUID=$PRODUCT
WSL_CUSTOMER_UUID=$CUSTOMER
WSL_JOB_TYPE_UUID=$JOB_TYPE
EOF
chmod 600 "$OUT"
echo "Done. Namespace $NS · product ${PRODUCT:-missing} · customer ${CUSTOMER:-missing}"
echo "Credentials written to build/local-fs-test.env (not printed)."
