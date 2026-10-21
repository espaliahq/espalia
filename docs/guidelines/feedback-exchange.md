# Feedback Exchange

> Read this when: touching anything under `app/integrations/feedback_exchange/`, `app/controllers/feedback_exchange/`, the signed-request concern, the exchange settings page, or a feature that sends feedback to, or takes it from, another feedback system. The contract is [the protocol](../notes/feedback-exchange-protocol.md); what GrowthOS builds on it is [the plan](../notes/feedback-integration-plan.md).

## What it is

Two feedback systems each serve the feedback given in them and pull the other's. GrowthOS plays both roles under one namespace, `FeedbackExchange`. The first peer is Chip. Nothing is pushed: a consumer pulls on its own schedule, so a missed run costs nothing.

Phase 0 is the foundation: config, secrets, signing, the client, the verifier, the health endpoint and the admin card. Phase 1 is the consumer: GrowthOS pulls the peer's feed and turns each record into unplaced feedback ([The consumer](#the-consumer)). The producer feed and placement suggestions land on top of it.

## Configuration

`Tenant#feedback_exchange_config` is a `FeedbackExchangeConfig` (StoreModel, JSONB), shaped like `HrisConfig`.

| Field | Meaning |
|---|---|
| `provider` | `exchange` for a protocol peer |
| `peer_name` | A slug, `chip`. It becomes `origin` and `external_reference.system` |
| `base_url` | The peer's exchange root **including its path prefix**, e.g. `https://chip.example.com/api/feedback-exchange`. https only, with no login, query or fragment, and not a private network host; development accepts http and local hosts |
| `enabled` | Off by default. While off, inbound requests get 404 and nothing is pulled |
| `import_kinds` / `export_kinds` | Which `kind`s cross. `export_kinds` are `EvidenceItem::EVIDENCE_TYPES`. `import_kinds` are matched against the peer's raw `kind`, so they also allow `feedback`, the one kind a conforming peer must send ("Any feedback (generic)" on the form). Both are validated and are checkbox groups on the settings form. Empty `import_kinds` means everything; ticking every box is narrower, since a kind not listed is left out. Empty `export_kinds` sends nothing |
| `cursor`, `deletions_cursor`, `last_synced_at` | Consumer state |
| `suggestions_enabled` | Placement suggestions, off by default |

`peer_name` and `base_url` are required once `enabled`. One peer per tenant for now.

An admin edits `base_url`, `peer_name`, `enabled` and the secrets on **Integrations → Feedback exchange**. Config edits are web-only on purpose: the page holds signing secrets, which must not travel through an MCP client. MCP gets the read `integrations_feedback_exchange_status`, which reports state and whether each secret and cursor is present, never a value. Its `connected` means set up (enabled, a peer, both secrets); only **Test connection** proves the peer answers.

## Secrets

`Tenant#feedback_exchange_credentials` is an encrypted JSON column, like `hris_credentials`:

```json
{ "outbound_secret": "…", "inbound_secret": "…",
  "previous_inbound_secret": "…", "previous_rotated_at": "2026-10-20T09:00:00Z" }
```

- **Outbound** signs what we send. The peer holds the same value as its *inbound* secret. **Inbound** verifies what the peer sends.
- Read them through `Tenant#feedback_exchange_secrets`, a `FeedbackExchangeSecrets` whose `inspect` and `to_s` print only whether a value is set. Do not read the raw column in new code, and never log a secret. The parameter filter already covers `*secret*`.
- **An inbound secret belongs to one workspace.** Saving an inbound secret whose key id another tenant holds, current or previous, is refused, since the secret is what tells the verifier whose request it is.
- The settings form never echoes a secret. A blank field keeps the stored value.
- **Rotation.** Saving a different inbound secret moves the old one to `previous_inbound_secret` and stamps `previous_rotated_at`. The verifier accepts the previous secret for 24 hours, so the two sides rotate without a coordinated deploy. Rotating the *outbound* secret has no window: change the peer's inbound value first, then ours.
- Each secret is at least 32 characters and the two differ (one secret per direction, protocol §6); `Tenant` refuses a save that breaks either, with a message on the form. Generate one with `openssl rand -hex 32` or `SecureRandom.hex(32)`.

## Signing (protocol §6)

`FeedbackExchange::Signature` is pure Ruby on ActiveSupport. It both signs and verifies.

```
X-Exchange-Timestamp: <unix seconds>
X-Exchange-Signature: v1=<hex HMAC-SHA256(secret, signing_string)>
signing_string = "v1:" + timestamp + ":" + METHOD + ":" + path_with_query + ":" + sha256_hex(raw_body)
```

- `path_with_query` is the path **as sent**, query string included and in the order sent. Sign what goes on the wire: `FeedbackExchange::Client` takes it from Faraday's own URL builder rather than rebuilding it.
- `raw_body` is the bytes as sent, empty for a GET. The verifier reads `request.raw_post`, never re-serialised params.
- **`X-Exchange-Key-Id: <first 16 hex of SHA-256(secret)>` is optional and recommended.** It sits outside the signature and names the secret that signed the request, so the verifier loads one tenant by an indexed lookup instead of decrypting and trying every credentialed tenant. Our client always sends it (`Signature.key_id`). Without it the verifier falls back to that scan, so a peer built before the header still works. A key id that matches no tenant, or is malformed, is refused with 401 without trying anyone.
- A timestamp more than 300 s from now is refused. The compare is constant-time and checks every accepted secret without short-circuiting.
- **Replays.** The verifier claims each accepted signature in `Rails.cache`, so a captured request cannot be sent twice. The claim lasts **twice** the 300 s window, because a timestamp is acceptable from five minutes before now to five minutes after, so a signature can stay valid for ten. A claim of one window would let a request signed in the future be replayed once it expired. The test environment uses a null cache store, so a test that exercises a replay must swap in a `MemoryStore`.

## The client

`FeedbackExchange::Client.for(tenant)` is Faraday with per-instance secrets and no global state, as `Hris::Hibob::Client` is. Methods: `feedback(since:, limit:)`, `deletions(since:, limit:)`, `ack(items)`, `health`. Every request carries `X-Exchange-Consumer: growthos` and a fresh signature.

Before it opens a connection it refuses a peer host that is not a canonical hostname or IP literal (so `127.1`, `2130706433`, `0x7f000001` and `0177.0.0.1` are out), or that is, or resolves to, a loopback, private, link-local, carrier-grade-NAT or reserved address, including IPv4 wrapped in IPv6 (`FeedbackExchange::HostGuard`, which resolves with `Addrinfo`, the resolver Net::HTTP uses). A tenant admin types the address and the server calls it, so without this "Test connection" probes internal services. It raises `Errors::AddressRefused`, whose message the page shows. The guard returns the public address it accepted and the client connects to exactly that address (`Net::HTTP#ipaddr`), keeping the hostname for TLS verification and the Host header, so a second DNS answer cannot redirect the request. Development is exempt.

It does **not** retry. The sync job owns retries, from the error class:

| Error | When | Job should |
|---|---|---|
| `AuthenticationError` | 401 | discard and tell a human |
| `RateLimitError` (`retry_after`) | 429 | retry after the stated delay |
| `ApiError` (`status`, nil if unreachable) | 5xx, other 4xx, no answer, a non-JSON body | retry with backoff |

## The consumer

`FeedbackExchange::SyncJob` pulls one tenant's feed; `FeedbackExchange::SyncAllTenantsJob` enqueues it for every tenant whose exchange is set up, every 15 minutes (`config/recurring.yml`). A run, inside the tenant:

1. Retries the ledger rows skipped for a reason our side can fix (below).
2. Pages through `GET /feedback` from `cursor`: imports every record on the page, acknowledges the ones that now live here (`remote_id` the evidence id, `remote_url` the assessment), then moves `cursor`. A run that dies mid-page redoes that page; the ledger and the deterministic ids make that safe.
3. Pages through `GET /feedback/deletions` from `deletions_cursor`, withdrawing each copy.
4. Stamps `last_synced_at`.

Cursors and `last_synced_at` are written through `Tenant#update_feedback_exchange!`, never by saving a config read earlier. `limits_concurrency` keeps one run per tenant. Errors follow `HrisSyncJob`: a 429 or a peer error retries with backoff, a 401 is discarded and logged, since a human has to fix the secret. At most 50 pages a run; the next run carries on.

### One record (`FeedbackExchange::Importer`)

- **People** match through `FeedbackExchange::PersonMatcher`: the id under the tenant's HRIS provider key in `external_ids`, else the lower-cased email (`Person.identified_by`). No match is a skip; a person is never created.
- **New record → unplaced evidence**, dispatched straight to `PersonDevelopment::CommandHandler#record_evidence` (the author may have no account) inside `AuditMetadata.with(acting_via: :feedback_exchange, actor_id: <author>, correlation_id: "<origin>:<id>")` and the tenant metadata. The evidence id is `UUIDv5(Importer::NAMESPACE, "<tenant_id>:<origin>:<id>")`, so a lost ledger row or a replay finds the same item. `source` comes from `EvidenceItem.source_for`; `evidence_type` is the record's `kind` when GrowthOS has that type, else `manager_feedback` or `peer_feedback`; the text goes through `FeedbackExchange::TextFormat` (below) with a request's question quoted above the answer; `external_reference` is `{ system: origin, external_id: id, url: source_url, metadata: { kind, request_context, requested_by_email, period_name, given_at, notified } }`.
- **Dated when given.** `recorded_at` on the event is the record's `given_at`, so reports count a backfill in the month it was given.
- **Counted in a cycle only when given in it.** `cycle_id` is the open cycle only when `given_at` falls inside the recipient's enrollment window there; otherwise nil, and reporting infers it as it does for history. A backfill of last year's feedback never counts as this cycle's.
- **Seen again**: a newer `updated_at` updates the content as the author; `status: withdrawn` withdraws it as the author ("Withdrawn in Chip"), and so does a newer version whose `audience` no longer covers everyone who can read it here (consent is data); a deletions-feed id withdraws it as the system ("Deleted in Chip"). An older or equal version is a no-op, and so is a blank edit. An item withdrawn in GrowthOS stays withdrawn and is not acknowledged.
- **A refused write never stops the page.** The domain can refuse an update or a withdrawal (the recipient was unassigned since, say); the importer logs it, leaves the ledger as it was and moves on, so one record cannot fail every run.
- **Silently.** The system the feedback was given in owns its notifications, so GrowthOS sends nothing on import: no arrival notice and no request to place it (`FeedbackNotifier` returns early for every `acting_via: feedback_exchange` event; `notified` is kept in the metadata only as part of the record). Imported feedback surfaces on the hub under "Feedback to place", and through placement suggestions ([#558](https://github.com/mr-yum/growth-os/pull/558)) once they are enabled. See [evidence.md](assessments/evidence.md).

### Skip reasons

Every outcome lands in `feedback_exchange_imports` (`FeedbackExchangeImport`), unique on (tenant, `origin`, `external_id`), with `status` `imported | updated | withdrawn | skipped`.

| `skip_reason` | Means | Retried |
|---|---|---|
| `echo` | `origin` is `growthos`, or the record's `external_reference.system` is | no |
| `audience_too_narrow` | the author did not agree to all of `recipient`, `management_line`, `hr`, who can read feedback here | no |
| `kind_not_imported` | `import_kinds` is set and leaves this kind out | no |
| `author_unmatched` / `recipient_unmatched` | no Person with that HRIS id or email | yes |
| `author_inactive` / `recipient_inactive` | our Person or the peer says that person is inactive (protocol §4.2) | yes |
| `self_feedback` | author and recipient are the same person | no |
| `no_assignment` | the recipient has no framework assignment | yes, and at once on `PersonAssignedToFramework` |
| `invalid_record` | no `id`, an `origin` that is not the configured peer, or the domain refused it | no |

A retriable skip keeps the record in the ledger's `record` column so a retry needs no pull; nothing else does. `FeedbackExchange::AssignmentRetry` (a sync handler subscribed in the RES initializer, never a projection) enqueues a sync when a newly assigned person has a `no_assignment` record waiting. A record skipped for a reason that is not retried is evaluated again if the peer sends a newer version.

The Integrations card and page show the counts, the skip reasons and the people the peer named that GrowthOS could not find; `integrations_feedback_exchange_status` returns the same under `imports` and `unmatched_people`.

### Text (`FeedbackExchange::TextFormat`)

`markdown` passes through. `slack` converts `*b*` → `**b**`, `_i_` → `*i*`, `~s~` → `~~s~~`, `•`/`◦` bullets (nested by four spaces) → `-`, `<url|text>` → `[text](url)`, `<@U…>` → the person's name through `TenantUser.slack_user_id`, else the name Slack carried, else `@someone`, and Slack's `&amp;`/`&lt;`/`&gt;`. `plain` escapes Markdown's characters. Both turn `label (url)`, the shape `Prose.to_plain` gives a link, back into `[label](url)`; the label runs back to the line start or the nearest `. ! ? : ; ,`. Code spans, code blocks, `> ` quotes and `1. ` lists are kept. The cases live in `test/fixtures/files/feedback_exchange/` as `<name>.<format>.txt` → `<name>.md` pairs, shared with the producer side.

### Replaying

To pull everything again, for instance after fixing people the peer named that GrowthOS did not know, clear the cursors and run a sync:

```ruby
tenant.update_feedback_exchange!(settings: { cursor: nil, deletions_cursor: nil })
FeedbackExchange::SyncJob.perform_later(tenant)
```

Records already imported come back as no-ops (or updates, if the peer changed them), because the ledger and the evidence ids are keyed on the record. Nothing is duplicated, and, imports being silent, nobody is notified.

## Inbound requests

`FeedbackExchangeSignedRequest` is the trust boundary, modelled on `SlackSignedRequest`. A controller inherits `ActionController::Base`, includes it and adds `around_action :authenticate_feedback_exchange_request!`. The signature is the only credential, so there is no Devise, no CSRF and no Pundit `authorize`.

A stale or malformed timestamp is refused before any tenant is loaded. Production throttles the path to 120 requests a minute per IP (`config/initializers/rack_attack.rb`), since each remaining request decrypts the credentialed tenants.

The concern finds the tenant by `X-Exchange-Key-Id` (the `inbound_key_id` or `previous_inbound_key_id` column, derived from the stored secrets on every save) and verifies only that tenant, or, when the header is absent, tries each credentialed tenant. Either way it takes the one whose inbound secret (or previous one, inside the window) verifies the request, claims the signature, and runs the action inside `ActsAsTenant.with_tenant`. Answers:

| Status | When |
|---|---|
| 401 | headers missing, signature or timestamp wrong, no tenant matches, or the signature was already used |
| 404 | the signature verifies but that tenant's exchange is disabled |

Routes sit under `/api/feedback_exchange/` in `config/routes.rb`. Note the underscore: Chip's own prefix is `/api/feedback-exchange`, which is why `base_url` includes the prefix instead of assuming one.

`GET /api/feedback_exchange/health` returns `{ "ok": true, "peer": "<peer_name>" }`.

## Verifying a pair

1. On Integrations → Feedback exchange, save the peer's address and both secrets.
2. Press **Test connection**. It sends a signed `GET <base_url>/health` and reports green only when the peer answers `{ "ok": true }`. It works before you enable the exchange. This proves the peer accepts *our* signature.
3. To prove the other direction, have the peer (or you, in a console) sign a request with the inbound secret:

   ```ruby
   ts  = Time.now.to_i.to_s
   sig = FeedbackExchange::Signature.sign(secret: inbound_secret, method: "GET",
           path_with_query: "/api/feedback_exchange/health", body: "", timestamp: ts)
   # curl -H "X-Exchange-Timestamp: #{ts}" -H "X-Exchange-Signature: #{sig}" \
   #   https://<growthos>/api/feedback_exchange/health
   ```

   A 200 means the pair works. The same request sent again within five minutes returns 401. A 404 means the exchange is still disabled.

## Testing

- Stub the peer with Faraday's test adapter (`Faraday::Adapter::Test::Stubs`) and inject the connection, as the HRIS client test does. `Client#initialize` takes `connection:`.
- To prove a request is signed over what was sent, verify it with `Signature.verify` using `env.url.request_uri` and `env.request_body`.
- Signature tests cover the round trip, wrong secret, missing headers, a stale timestamp, a tampered body, a swapped method or path, and the rotation window on both sides of 24 hours.

## Gotchas

- `base_url` must carry the peer's prefix. A client pointed at the bare host signs a path the peer never serves.
- Sign what Faraday sends. Hand-building a query string can order or encode it differently from the wire, and the peer's check then fails with a bare 401.
- **Two identical requests within one second share a signature**, and the replay guard refuses the second. Space retries by more than a second; do not read that 401 as a wrong secret.
- **Write settings through `Tenant#update_feedback_exchange!`.** It locks and reloads the row first. Anything that writes `feedback_exchange_config` from a job (the cursors, `last_synced_at`) must do the same, or an admin saving the form overwrites it with stale values, and the reverse.
- **A test that imports must give the importer a tenant with the exchange set up** (`test/support/feedback_exchange_records.rb` has `connect_feedback_exchange` and `exchange_record`, built on `test/fixtures/files/feedback_exchange/record.json`).
- **The importer dispatches command handlers itself, so it wraps them in `AuditMetadata.wrap_event_store`.** `AuditMetadata.with` alone only sets the thread-local; outside an Operation nothing copies it onto the events, and `acting_via` would be missing.
