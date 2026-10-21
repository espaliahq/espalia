# Feedback Exchange

> Read this when: touching anything under `app/integrations/feedback_exchange/`, `app/controllers/feedback_exchange/`, the signed-request concern, the exchange settings page, or a feature that sends feedback to, or takes it from, another feedback system. The contract is [the protocol](../notes/feedback-exchange-protocol.md); what GrowthOS builds on it is [the plan](../notes/feedback-integration-plan.md).

## What it is

Two feedback systems each serve the feedback given in them and pull the other's. GrowthOS plays both roles under one namespace, `FeedbackExchange`. The first peer is Chip. Nothing is pushed: a consumer pulls on its own schedule, so a missed run costs nothing.

Phase 0 is the foundation: config, secrets, signing, the client, the verifier, the health endpoint and the admin card. Phase 3, the producer feed, is built on it (see *Serving the feed*). Nothing calls the client yet. The importer and suggestions land on top.

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

## Serving the feed (GrowthOS as producer)

Three more signed endpoints, all `ActionController::Base` controllers that include `FeedbackExchangeProducer` (the signed-request concern plus the consumer name and a 400 for a bad cursor, limit or body). Nothing here is an MCP tool: the peer is the only caller and the credential is a shared secret, not a user.

| Endpoint | Controller | Answers |
|---|---|---|
| `GET /api/feedback_exchange/feedback?since=&limit=` | `FeedbackExchange::FeedController` | `{ items, next_cursor, has_more }` |
| `GET /api/feedback_exchange/feedback/deletions` | `DeletionsController` | always `{ items: [], next_cursor: <since>, has_more: false }`; GrowthOS withdraws, never deletes |
| `POST /api/feedback_exchange/feedback/ack` | `AcksController` | 204; `400` for a malformed body |

**The feed** (`FeedbackExchange::Feed`) reads `EvidenceItem` rows keyset-paged on `(updated_at, id)`. The cursor (`FeedCursor`) is URL-safe base64 of `[updated_at at microsecond precision, id]`; an edit or withdrawal moves a row to a newer position, so it comes back, and a row inserted mid-walk sorts after the cursor and is never skipped. `limit` defaults to 100 and is capped at 200; zero, negative or non-integer is a 400, as is a cursor we did not issue. An empty page hands the caller's own cursor back. A cursor must end in `Z`. Keyset paging on a timestamp has the usual limit: a row that commits late with an `updated_at` behind the cursor (a long transaction that began before a faster one) is missed until the peer resets its cursor. Projection writes are short, so the window is small; a peer that needs certainty can overlap its `since` slightly, as records are idempotent. The cursor advances over every row read, including rows the serializer then skips, so an unnameable person cannot stall it.

What is left out (protocol §2.5, §2.3):

- `source: self`, a person's own self-assessment evidence.
- Items nobody wrote: `recorded_via` of `feedback_exchange`, `hris` or `system`. A nil `recorded_via` is history and counts as human.
- What the asking consumer itself sent us: `external_reference.system` equal to its name. Matching is case-insensitive.
- Another system's import that the consumer has since acknowledged (an ack row from this consumer for an item whose `external_reference.system` is not a plain link target such as `github`). An ack on an ordinary item does not hide it. Imports through the exchange itself never get this far: `recorded_via: feedback_exchange` is already left out.
- Kinds outside `export_kinds`.

The consumer is the tenant's configured `peer_name`. The `X-Exchange-Consumer` header, lower-cased, must equal it or the request is a 400, because the signature does not cover the header; a request without one is that peer.

**The record** (`FeedbackExchange::Record`) is protocol §4 field by field: `kind` is `evidence_type`; `text_format` is `markdown`; `audience` is always `[recipient, management_line, hr]` (who can read it here) and `notified` always `[recipient, manager]`; `status` is `link_status`, so a withdrawn item travels with `status: "withdrawn"` and an empty `text` (the consumer needs only the status, and the author took the words back); `request` is the answered `evidence_requests` row (`context` is the ask's message); `period` is the item's cycle; `source_url` is the assessment deep link with the cell params, or the feedback hub anchor for an unplaced item; `external_reference` is set only for an item that itself came in through the exchange. A title leads the text as a bold line, because the protocol has no field for it. People are `{ email, display_name, active, external_ids: { <hris_source>: <external_id> } }` and no internal id ever leaves. A record whose author or recipient is gone, or has no email, is skipped. `source_url` is null when the app has no host configured, rather than failing the page.

**Cost.** One query for the page, then one each for people, answered requests, cycles and assessment ids, however many items the page holds. `feed_controller_test.rb` asserts the query count is the same for one item and six.

**Acks** land in `feedback_exchange_acks` (tenant, `evidence_id`, `consumer`, `remote_id`, `remote_url`; unique on item × consumer). `FeedbackExchangeAck.record_all` validates the whole page first and writes nothing if any item is malformed, skips ids that are not this tenant's items, then upserts, so a repeat is a no-op and a changed link updates the row. `remote_url` is shown to people, so it must be http(s). The evidence card reads them (`EvidenceItem.load_exchange_acks`, one query) and links "Also in Chip" to the peer.

**`recorded_via`** is `evidence_items.recorded_via`, written by `EvidenceCollection` from the event's `acting_via` metadata. It is additive and nil on history, so there is no `CODE_VERSION` bump; a rebuild of the projection backfills it. A rebuild also re-inserts every row with a new `updated_at`, so the whole feed reappears once. Consumers are idempotent on `(origin, id)`, so that costs bandwidth, not correctness.

**Things the importer must know.** `ExternalReference` validates `system` against a fixed list of link targets, which a peer's name is not. The feed filters in SQL on the raw JSON, so it does not care, but the importer that records `{ system: "chip", … }` has to extend that list or write the column directly. `AuditMetadata::ACTING_VIA` has no `feedback_exchange` yet; the importer adds it, and the feed already excludes the value.

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
4. To read the feed the same way, sign `GET /api/feedback_exchange/feedback?limit=2` (the query string is part of the signed path), then repeat with `since=<next_cursor>` and a fresh timestamp; only newer rows come back.

## Testing

- Stub the peer with Faraday's test adapter (`Faraday::Adapter::Test::Stubs`) and inject the connection, as the HRIS client test does. `Client#initialize` takes `connection:`.
- To prove a request is signed over what was sent, verify it with `Signature.verify` using `env.url.request_uri` and `env.request_body`.
- Signature tests cover the round trip, wrong secret, missing headers, a stale timestamp, a tampered body, a swapped method or path, and the rotation window on both sides of 24 hours.

## Gotchas

- `base_url` must carry the peer's prefix. A client pointed at the bare host signs a path the peer never serves.
- Sign what Faraday sends. Hand-building a query string can order or encode it differently from the wire, and the peer's check then fails with a bare 401.
- **Two identical requests within one second share a signature**, and the replay guard refuses the second. Space retries by more than a second; do not read that 401 as a wrong secret.
- **Write settings through `Tenant#update_feedback_exchange!`.** It locks and reloads the row first. Anything that writes `feedback_exchange_config` from a job (the cursors, `last_synced_at`) must do the same, or an admin saving the form overwrites it with stale values, and the reverse.
- The Integrations card's counts section is a placeholder until the importer ships.
