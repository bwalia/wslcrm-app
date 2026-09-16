# OpsAPI gaps, inconsistencies and bugs found while building WSLCRM iOS

The backend was **not** modified. These notes come from reading `opsapi/lapis` (read-only) and from
probes against `int-opsapi.workstation.co.uk`. Source references are relative to `opsapi/lapis/`.
Items marked **(verified on int)** were reproduced live; the rest come from the code and still
need confirming against the live database.

## 1. Security — please triage first

1. **`X-Public-Browse: true` bypasses tenant isolation.** `middleware/auth.lua:60-67` clears
   `current_user` when the header is present, after the global filter has already accepted the
   token. `requireNamespace` then skips the membership check (`middleware/namespace.lua:220-228`).
   The result: any valid token plus another tenant's `X-Namespace-Id` can list that tenant's
   field-service jobs and visits (unscoped, including customer names, phones and addresses) and
   can **read, update and delete their CRM data**. The app never sends this header.
2. **CRM routes enforce no RBAC.** `routes/crm-*.lua` only check auth and namespace, so any active
   member can create, update and delete every account, contact, deal and pipeline. The `crm_*`
   modules only affect menu visibility. (The app hides CRM actions by `crm_accounts` permission,
   but the server does not.)
3. **Products `orderBy` / `orderDir` are concatenated into SQL** (`queries/StoreproductQueries.lua`) — SQL injection.
4. **`GET /api/v2/products` is not tenant-scoped.** It returns active products from every namespace
   unless `store_id` is passed, and an unknown `store_id` silently returns everything.
   `PUT` / `DELETE /products/:id` don't check the product belongs to the current namespace.
5. **Orders ignore namespaces entirely.** Access comes from the global role or store ownership.
   `/orders/:id/status-history` and `/available-transitions` have no ownership check.
   `GET /api/v2/orderitems` lists order items across all stores.
6. Engineers can read every service request, stats for the whole namespace, and the invoice preview
   of **any** job (`guard` is `fs_jobs.read`), plus all visits, items and activity on any job where
   they hold a visit, even a cancelled one.

## 2. Contract / documentation drift

7. **`openapi.json` is wrong for auth (verified on int).**
   - `/auth/login` takes **form-encoded** `identifier` (or `username`) + `password`, not a JSON
     `email`. A JSON body always returns `400 VALIDATION_400 field=identifier`.
   - `/auth/2fa/verify` needs `code` (a string), not `otp`.
   - The verify response has `current_namespace` (not `default_namespace`) and no `success`.
   - `/auth/me` returns `{user, namespaces, current_namespace}`, not `{success, data}`.
8. **`openapi.json` has no `/api/v2/orders*` paths.** `helper/openapi_generator.lua:895` only
   discovers `app:get|post|put|delete`, so every `app:match` route is missing.
9. **Order status is `PUT`, not `POST`.** The summary's `POST /orders/:id/status` returns 405.
   There are two competing routes: `PUT /orders/:id/status` (no transition validation) and
   `PUT /orders/:id/update-status` (validated, store owner only — admins get 403). A third status
   map lives in `/seller/orders/:uuid/status`, and each uses different status names
   (`shipped` vs `packing`/`shipping`).
10. **Field-service payloads are typed as a generic `object`** in `openapi.json`. The iOS models
    were hand-written from `queries/FieldService*Queries.lua`.
11. **Invoice OpenAPI is out of date.**
    - Paging is `perPage`, and meta keys are `perPage` / `totalPages` (not `per_page`).
    - `Invoice.id` is the uuid string, with `internal_id` holding the number.
    - Payments use `reference_number` (not `reference`); line items use `discount_percent`.
12. **Customer and product OpenAPI is out of date.**
    - Paging is `perPage` (camelCase); `per_page` is ignored.
    - Customers have no `search`.
    - Neither envelope has `success`.
13. Stale route header comments list filters that don't exist: `account_uuid` / `site_uuid` on jobs,
    `account_uuid` / `asset_uuid` on service requests.
14. `FIELD_SERVICE_COMPLAINT_MANAGEMENT_PLAN.md` still describes the pre-v2 schema
    (sites, assets, CRM links).

## 3. Inconsistencies the client has to absorb

15. **Five envelope styles:**
    - field service / CRM: `{success, data, meta{per_page}}`
    - customers / products: `{data, total}`
    - orders: top-level `data, total, page, per_page, total_pages`
    - invoices: `{success, data, meta{perPage, totalPages}}`
    - auth and menu: bare objects
16. **At least five error shapes:**
    - `{error}` (+`reason` / `message` / `details` / `retry_after` / `required` / string `status`)
    - `{success:false, error}`
    - catalogued `{error:{code, title, message, correlation_id, occurrence_uuid, context}}`
    - `{error:{code, category, message}}` for 404/405
    - legacy `{error:{code:<int>, message, field}}`
17. **Empty Lua tables serialise as `[]` everywhere.** `cjson.encode_empty_table_as_object(false)` is
    set globally (`routes/permissions.lua:14`), so empty objects such as `metadata`, `permissions`,
    `customer_address` and the CRM deals-by-stage map arrive as `[]`.
18. **NULL columns are omitted**, not sent as `null`. Timestamps are naive UTC with 0–6 fractional
    digits; dates are `YYYY-MM-DD`.
19. **JSON stored in TEXT columns comes back as a string:** customer `addresses`, product `images` /
    `variants`, role `permissions` in `/user/namespaces`. Some legacy defaults were written with
    literal quotes (`'USD'`, `'[]'`).
20. **CRM relations are numeric ids only.** Responses never include related uuids. `PUT` accepts only
    numeric FKs, and `*_uuid` works only on `POST` — silently ignored if it doesn't resolve.
21. **`PUT` returns `data: true` instead of the record** for CRM accounts, contacts, deals, pipelines
    and products. CRM activity update and complete return **500** even though the change is saved.
22. **`allowed_transitions` is only on job detail and service-request detail.** Phases have no
    transition map; visits are driven by endpoints.
23. **Field-service `from_error` maps any message containing "not found" to 404**, so a body
    reference error (`Customer not found`, `Checklist item not found`) looks like a missing path.
24. **Input timestamps with a UTC offset are silently misread** (`"10:00+01:00"` is stored as 10:00).
    Only `Z` is safe.
25. **A page size of `0` returns 500** everywhere (NaN in `total_pages`), and a negative page returns
    500. CRM has no `per_page` upper bound.
26. **After `/auth/refresh`, the JWT points at the user's *default* namespace**, not the last one
    switched to. Clients must always send `X-Namespace-Id`.
27. **Deal stages have no schema and none are seeded.** Only stage names `won` / `lost` set status;
    the web UI uses `closed_won` / `closed_lost`, which do nothing. Reopening a won deal doesn't
    reset `status`.
28. **Invoice status:** the server only writes `draft` / `sent` / `paid` / `void`. `partially_paid` and
    `overdue` must be derived on the client.

## 4. Bugs

29. **`GET /api/v2/orders/:id` likely returns 500 for every order.** It selects `order_history.uuid,
    previous_status, tracking_url`, which aren't in the migration. `PUT /orders/:id/status` writes
    the same columns *after* committing the status, then returns 500. On presets without the
    delivery feature the detail also joins non-existent tables.
30. **Order routes ignore JSON bodies** (Lapis only parses form data), so a JSON status update is a
    silent no-op that returns 200. The web dashboard's `updateOrderStatus` has this bug.
31. **Invoice totals don't add up.** `discount_amount` is always 0 (it reads a non-existent item
    column) and `subtotal` is pre-discount, so `subtotal − discount + tax ≠ total` when lines have
    discounts.
32. **Invoice status guards are missing.** Line items can be added, edited or deleted on paid and
    void invoices. `void` is allowed from `paid`. Overpayment gives a negative balance. Recording a
    payment on an unknown invoice returns 400 instead of 404.
33. **Invoice writes aren't transactional.** Create-with-items can leave a header with no items.
    The invoice number sequence is read-then-update, so concurrent creates can collide.
34. **`POST /api/v2/documents/generate/invoice/:uuid` selects non-existent columns**
    (`invoice_date`, `payment_terms`) and there is **no PDF download**. The iOS app renders PDFs
    on device.
35. **Visit check-out is not transactional.** The visit completes even if phase completion or
    timesheet logging fails, and those failures only appear in `warnings` with HTTP 200. The app
    shows them. An auto-computed labour time over 24 h makes check-out fail until `labour_hours`
    is sent.
36. **Job approval integrity:**
    - `PUT /job-items/:uuid` doesn't reset `approval_status`, so an approved part's quantity or
      price can change after approval.
    - Approve and reject have no state guard, and `approved_at` is stamped on rejection too.
    - `JobTotals.items_value` includes pending and rejected items.
37. **`PUT /jobs/:uuid` silently ignores `service_address`, `service_postcode` and `product_ref`**
    (the dashboard sends them).
38. **A completed, no-access or cancelled visit can't be reopened.** Deleting a visit that's logged
    to a timesheet says "cancel it instead", but cancel only accepts scheduled / en-route visits.
39. **Job cancellation leaves `on_site` visits open.** Converting a resolved request back to
    in-progress doesn't clear `resolved_at`. `/assign` ignores the transition map.
40. **`status=all` returns zero service requests** (it is treated as a literal status); it works
    for jobs and visits.
41. **Product create/update pass the body straight into SQL.** Unknown keys, arrays or `null`
    return 500, and product `DELETE` hard-deletes the product's order items.
42. **`/orders/stats` omits `cancelled_orders` / `pending_revenue`** for sellers without stores,
    and sums revenue across currencies (as do CRM and invoice stats).
43. **An 11th device login silently invalidates the oldest session** (10 refresh tokens per user).

## 5. Field Service engineer app (opsapi #610, `feat/field-service-engineer-app`)

Found while mirroring #610 (on top of #607 / #604) and running the iOS happy path against that
branch locally. The app works around each one. Items marked **(verified locally)** were reproduced
on the PR branch.

44. **`site_uuid` is dropped on create (verified locally).** `RequestQueries.createRequest` resolves
    `site_uuid` to `refs.site_id` (`queries/FieldServiceRequestQueries.lua:260`) but never writes
    `site_id` in `FsServiceRequestModel:create`. `JobQueries.createJob` has the same omission, so
    `POST /jobs` and `POST /service-requests/:uuid/convert-to-job` also create site-less jobs.
    Update is fine. The app sends a follow-up `PUT {site_uuid}` after create or convert
    (`FieldServiceAPI.createServiceRequest` / `convertToJob`, covered by a unit test).
45. **There is no assets API.** `fs_assets` (migration 862) was dropped in field-service v2 (884).
    The serviced asset is now the customer's store product, with `product_ref` as the unit serial,
    and the dashboard menu entry for assets is gone. iOS "Assets" is therefore a store-product
    search, and an asset's history comes from `GET /jobs?product_uuid=` and
    `GET /service-requests?product_uuid=`.
46. **Job search doesn't include `product_ref`** (`FieldServiceJobQueries.lua:368`), so a unit
    can't be found by its serial number.
47. **Notifications are not namespace-scoped** (`routes/notifications.lua`). A user in two
    workspaces sees both workspaces' "job assigned" notifications. Paging is `limit`/`offset`
    with no `total`.
48. **No mobile-friendly "my work" endpoint.** The engineer home screen is built from
    `GET /visits?engineer_uuid=me` over a date window (−3 to +21 days, `per_page` ≤ 200), with the
    job re-fetched per visit for checklists. A single `GET /field-service/my-work` (today's visits,
    their job, phase checklists and site) would cut this to one cached call. There is also no
    push for new assignments: the app polls every 30s while in the foreground and diffs visit
    uuids locally.
49. **Local test-tenant setup hits several unrelated bugs (verified locally):**
    - `PUT /api/v2/users` returns 500 because it writes a missing `updated_by` column (`routes/users.lua:245`).
    - `POST /api/v2/stores` returns 500 because it writes a missing `created_by` column (`routes/stores.lua:121`).
    - Users created via `POST /api/v2/users` are inactive and can't log in until activated.
    - `POST /api/v2/register` is unusable when `PROJECT_CODE=all`.

    `scripts/local-opsapi-fs-seed.sh` works around these with SQL on the isolated local database only.

50. **Job photos lose their content type (verified locally).** The upload route reads
    `file.content_type` (`routes/field-service-jobs.lua:233`), but Lapis's multipart parser doesn't
    provide it, so `fs_job_photos.content_type` is always NULL and never comes back in the API.
    The create response also omits `created_at` (the list has it). Photos are therefore untyped
    and unordered for the client.
51. **The photo size limit is really 10MB, not 15MB (verified locally).** The route rejects over
    15MB (`routes/field-service-jobs.lua:224`), but the upload then goes through
    `MinioClient:validateFile`, which enforces `MAX_FILE_SIZE = 10MB` (`helper/minio.lua:218`) and
    surfaces as a **502** "Upload failed: File size …" rather than a 413. The app caps uploads at
    10MB and maps that 502 to a "photo is too large" message.
52. **Photo URLs are presigned for one hour** (`queries/JobPhotoQueries.lua:25-32`, re-signed on
    every read), so a client must not persist them; the app re-fetches the list instead.
53. **The global rate limiter answers 429 with `retry_after` in the body and a `Retry-After`
    header** (`middleware/rate-limit.lua:67-89`), but outside a 429 only `X-RateLimit-Limit` and
    `X-RateLimit-Remaining` are sent. The body is a bare `{error, retry_after}` — not the usual
    envelope — so 429 needs its own decoding path.

## 5b. Quotation, emailed documents and roles (opsapi #611)

54. **The Service Manager role cannot send an invoice (verified locally).** The seeded role has
    `invoices: ["create", "read"]`, but `POST /invoices/:uuid/send` and the new
    `POST /invoices/:uuid/email` both require `invoices.update`
    (`routes/invoices.lua`, `requirePermission("invoices", "update")`). So the person who raises
    the invoice can't email it or mark it sent — only an owner/admin can. Either the seed needs
    `invoices: ["manage"]` (or `update`), or sending should be guarded by `invoices.create`.
    The app hides both actions unless the caller has `invoices.update`.
55. **The new `products: manage` grant only reaches new workspaces.** `createFieldServiceRoles`
    skips a role that already exists, so workspaces seeded before #611 keep a Service Manager with
    no `products` grant (confirmed on the local tenant: the menu has no `products` key). Existing
    tenants need the role editor or a migration. The app gates the product editor on the grant, so
    it simply stays hidden.
56. **PDFs are the client's job.** `POST /jobs/:uuid/quote-email` and `POST /invoices/:uuid/email`
    both require `pdf_base64` from the caller — there is no server-side renderer — so every client
    has to reproduce the same document. The iOS app renders both on device (`DocumentPDF`).
    A server-rendered PDF (or an endpoint that builds it from the job) would keep the documents
    identical across clients.
57. **Emailing an invoice marks it sent, but sending is not idempotent.** `/email` flips a draft to
    `sent` after the mail goes out; a second call emails again. There's no "sent at" timestamp to
    show the customer's last copy.
58. **Fault categories are per-tenant free text.** `GET /field-service/fault-categories` returns
    distinct values already used, most-used first, and a new one is created simply by saving it on
    a request. There's no rename or merge, so a typo becomes a permanent option in the list.

## 6. Missing endpoints that would simplify the app

- `GET /job-phases/:uuid` — phase mutations return only the phase, so the job has to be re-fetched
  for roll-ups.
- Related uuids on field-service and CRM rows: `service_request_uuid` on jobs, and `account_uuid`,
  `contact_uuid` and `pipeline_uuid` on CRM rows.
- A namespace-scoped product list, and a namespace-scoped store list (`/my/stores` is per user and
  ignores the namespace).
- A working order detail, plus an order status route that accepts JSON and lets admins update.
- An invoice PDF download.
- APNs device-token registration (the server is FCM-only, which would force a Firebase dependency).
- Idempotency keys on field-service mutations, so offline replays can be retried safely if a
  response is lost.
- `GET /field-service/my-work` for the engineer home screen (see 48), and an assets or serial
  search that covers `product_ref` (see 45–46).
