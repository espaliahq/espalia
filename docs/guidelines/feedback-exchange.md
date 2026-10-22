# Feedback Exchange

> Read this when: touching anything under `app/integrations/feedback_exchange/`, `app/controllers/feedback_exchange/`, the signed-request concern, the exchange settings page, or a feature that sends feedback to, or takes it from, another feedback system. The contract is [the protocol](../notes/feedback-exchange-protocol.md); what GrowthOS builds on it is [the plan](../notes/feedback-integration-plan.md).

## What it is

Two feedback systems each serve the feedback given in them and pull the other's. GrowthOS plays both roles under one namespace, `FeedbackExchange`. The first peer is Chip. Nothing is pushed: a consumer pulls on its own schedule, so a missed run costs nothing.

Phase 0 is the foundation: config, secrets, signing, the client, the verifier, the health endpoint and the admin card. Two roles are built on it: the consumer, which pulls the peer's feed and turns each record into unplaced feedback ([The consumer](#the-consumer)), and the producer, which serves GrowthOS's own feedback (see *Serving the feed*). Placement suggestions help place what the consumer imports.

## Configuration

`Tenant#feedback_exchange_config` is a `FeedbackExchangeConfig` (StoreModel, JSONB), shaped like `HrisConfig`.

| Field | Meaning |
|---|---|
| `provider` | `exchange` for a protocol peer |
| `peer_name` | A slug, `chip`. It becomes `origin` and `external_reference.system` |
| `base_url` | The peer's exchange root **including its path prefix**, e.g. `https://chip.example.com/api/feedback-exchange`. https only, with no login, query or fragment, and not a private network host; development accepts http and local hosts |
| `enabled` | Off by default. While off, inbound requests get 404 and nothing is pulled |
| `import_kinds` / `export_kinds` | Which `kind`s cross. Both default to `["all"]` (`FeedbackExchangeConfig::ALL_KINDS`): every type, resolved when read, so a type added to `EvidenceItem::EVIDENCE_TYPES` later is sent, and any kind the peer sends is imported, without anyone saving again. Any other list means exactly its types, and an empty list means none: nothing sent, nothing imported. `export_kinds` are `EvidenceItem::EVIDENCE_TYPES`. `import_kinds` are matched against the peer's raw `kind`, so they also allow `feedback`, the one kind a conforming peer must send ("Any feedback (generic)" on the form). Read them through the config's `exports_all_kinds?`, `exported_kinds` and `imports_kind?(kind)`, never the raw arrays. On the settings form each is a checkbox group led by **All types** (value `all`), ticked by default; while it is ticked the `all-kinds` Stimulus controller greys out the type boxes, and unticking it gives back the choice held before. Without JavaScript the boxes stay live and post beside `all`; the config's writers keep only `["all"]` whenever a list holds it, whoever writes it |
| `cursor`, `deletions_cursor`, `last_synced_at` | Consumer state |

`peer_name` and `base_url` are required once `enabled`. One peer per tenant for now. Placement suggestions are not switched here: **Integrations → AI model** holds the one switch, which covers every evidence item whatever surface it came from.

An admin edits `base_url`, `peer_name`, `enabled` and the secrets on **Integrations → Feedback exchange**. Config edits are web-only on purpose: the page holds signing secrets, which must not travel through an MCP client. MCP gets the read `integrations_feedback_exchange_status`, which reports state and whether each secret and cursor is present, never a value. It returns both kind lists as stored, so `["all"]` reads as all, and `exported_kinds`, what the feed sends today. Its `connected` means set up (enabled, a peer, both secrets); only **Test connection** proves the peer answers.

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
| `PeerDisabled` (an `ApiError`) | 404: the peer has the exchange switched off | log and stop the run, no retry |
| `Conflict` (an `ApiError`) | 409 to an ack: the peer could not record it | log as the bug it is and carry on, no retry |
| `RateLimitError` (`retry_after`) | 429 | retry after the stated delay |
| `ApiError` (`status`, nil if unreachable) | 5xx, other 4xx, no answer, a non-JSON body | retry with backoff |

## The consumer

`FeedbackExchange::SyncJob` pulls one tenant's feed; `FeedbackExchange::SyncAllTenantsJob` enqueues it for every tenant whose exchange is set up, every 15 minutes (`config/recurring.yml`). A run, inside the tenant:

1. Retries the ledger rows skipped for a reason our side can fix (below).
2. Pages through `GET /feedback` from `cursor`: imports every record on the page, acknowledges the ones that now live here (`remote_id` the evidence id, `remote_url` the assessment), then moves `cursor`. A run that dies mid-page redoes that page; the ledger and the deterministic ids make that safe.
3. Pages through `GET /feedback/deletions` from `deletions_cursor`, withdrawing each copy.
4. Stamps `last_synced_at`.

Cursors and `last_synced_at` are written through `Tenant#update_feedback_exchange!`, never by saving a config read earlier. `limits_concurrency` keeps one run per tenant. Errors follow `HrisSyncJob`: a 429 or a peer error retries with backoff, a 401 is discarded and logged, since a human has to fix the secret. A 404 means the peer has the exchange off: the run stops, logged, with no retry and no `last_synced_at`. A `base_url` without the peer's path prefix also gets 404s, so a tenant whose `last_synced_at` stays empty is worth a **Test connection**. A 409 to an ack is logged and the run carries on, since retrying the same ack cannot succeed. At most 50 pages a run; the next run carries on.

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
| `kind_not_imported` | `import_kinds` is not `all` and does not list this kind (an empty list imports nothing) | no |
| `author_unmatched` / `recipient_unmatched` | no Person with that HRIS id or email | yes |
| `author_inactive` / `recipient_inactive` | our Person or the peer says that person is inactive (protocol §4.2) | yes |
| `self_feedback` | author and recipient are the same person | no |
| `no_assignment` | the recipient has no framework assignment | yes, and at once on `PersonAssignedToFramework` |
| `invalid_record` | no `id`, no usable `given_at`, an `origin` that is not the configured peer, a malformed nested part, or the domain refused it | no |

The import list decides what is taken in, not what is kept. A copy GrowthOS already holds keeps following its source after the list narrows: an edit updates it and a withdrawal withdraws it, so narrowing never leaves a stale copy behind. Only consent is re-checked on every version, because an audience that no longer covers our readers takes the copy back (protocol rule 1).

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

Records already imported come back as no-ops (or updates, if the peer changed them), because the ledger and the evidence ids are keyed on the record. Nothing is duplicated, and, imports being silent, nobody is notified. A record skipped for a reason that is not retried is assessed again, so a cursor reset is also the backfill after widening `import_kinds`.

### Testing against a real peer

The first end-to-end run against Chip (21 Oct 2026, written up on Linear AIX-3392) left three rules for the next one. Use **synthetic people** on both sides: the dev database carries real colleagues' emails from the HiBob sync, and a test with those would attach made-up feedback to real people. Keep the **seeded demo evidence out of the feed**: it is between real addresses, the peer would skip every item as unmatched, and its skip log would then hold those addresses (in a throwaway staging database, marking the demo items `recorded_via: "system"` hides them, since the feed excludes non-human recorders). And expect the **evidence ids to change** if the staging tenant is re-seeded, because they are UUIDv5 over the tenant id; the peer must then accept a re-ack with a new id (latest ack wins, protocol §5.3).

## Inbound requests

`FeedbackExchangeSignedRequest` is the trust boundary, modelled on `SlackSignedRequest`. A controller inherits `ActionController::Base`, includes it and adds `around_action :authenticate_feedback_exchange_request!`. The signature is the only credential, so there is no Devise, no CSRF and no Pundit `authorize`.

A stale or malformed timestamp is refused before any tenant is loaded. Production throttles the path to 120 requests a minute per IP (`config/initializers/rack_attack.rb`), since each remaining request decrypts the credentialed tenants.

The concern finds the tenant by `X-Exchange-Key-Id` (the `inbound_key_id` or `previous_inbound_key_id` column, derived from the stored secrets on every save) and verifies only that tenant, or, when the header is absent, tries each credentialed tenant. Either way it takes the one whose inbound secret (or previous one, inside the window) verifies the request, claims the signature, and runs the action inside `ActsAsTenant.with_tenant`. Answers:

| Status | When |
|---|---|
| 401 | headers missing, signature or timestamp wrong, no tenant matches, the signature was already used, or `X-Exchange-Consumer` is missing or names anyone but the tenant's `peer_name` |
| 404 | the signature verifies but that tenant's exchange is disabled |

Routes sit under `/api/feedback_exchange/` in `config/routes.rb`. Note the underscore: Chip's own prefix is `/api/feedback-exchange`, which is why `base_url` includes the prefix instead of assuming one.

`GET /api/feedback_exchange/health` returns `{ "ok": true, "peer": "<peer_name>" }`.

`GET /api/feedback_exchange/feedback/contract` is the one exchange route outside the signed-request concern (protocol §5.5). It is unsigned, has no tenant, answers whatever any tenant's exchange is set to, and may be cached for five minutes: `{ "protocol": "v1", "build": <release id>, "consumer_pact": <contract/pacts/growthos-chip.json> }`. The peer's provider verification fetches our pact from it (see [Contract tests](#contract-tests-pact)). It is not an MCP tool: it is a static artefact for the peer, not a user surface.

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
- Kinds outside `export_kinds`. With `all`, that is every type in `EvidenceItem::EVIDENCE_TYPES` at the time of the request, so a type added later is sent and a row holding a type GrowthOS no longer knows is not.

**Widening `export_kinds` does not backfill.** The peer's cursor has already passed the older items of a newly sent kind, so only new and edited ones reach it. For the history, the peer resets its cursor; records are idempotent, so the rest come back as no-ops.

The consumer is the tenant's configured `peer_name`. The signature does not cover the `X-Exchange-Consumer` header, so the signed-request concern refuses a request with 401 unless the header, lower-cased, equals it; a request without one is refused too.

**The record** (`FeedbackExchange::Record`) is protocol §4 field by field: `kind` is `evidence_type`; `text_format` is `markdown`; `audience` is always `[recipient, management_line, hr]` (who can read it here) and `notified` always `[recipient, manager]`; `status` is `link_status`, so a withdrawn item travels with `status: "withdrawn"` and an empty `text` (the consumer needs only the status, and the author took the words back); `request` is the answered `evidence_requests` row (`context` is the ask's message); `period` is the item's cycle; `source_url` is the assessment deep link with the cell params, or the feedback hub anchor for an unplaced item; `external_reference` is set only for an item that itself came in through the exchange. A title leads the text as a bold line, because the protocol has no field for it. People are `{ email, display_name, active, external_ids: { <hris_source>: <external_id> } }` and no internal id ever leaves. A record whose author or recipient is gone, or has no email, is skipped. `source_url` is null when the app has no host configured, rather than failing the page.

**Cost.** One query for the page, then one each for people, answered requests, cycles and assessment ids, however many items the page holds. `feed_controller_test.rb` asserts the query count is the same for one item and six.

**Acks** land in `feedback_exchange_acks` (tenant, `evidence_id`, `consumer`, `remote_id`, `remote_url`; unique on item × consumer). `FeedbackExchangeAck.record_all` validates the whole page first and writes nothing if any item is malformed, skips ids that are not this tenant's items, then upserts, so a repeat is a no-op and a changed link updates the row. `remote_url` is shown to people, so it must be http(s). The evidence card reads them (`EvidenceItem.load_exchange_acks`, one query) and links "Also in Chip" to the peer.

**`recorded_via`** is `evidence_items.recorded_via`, written by `EvidenceCollection` from the event's `acting_via` metadata. It is additive and nil on history, so there is no `CODE_VERSION` bump; a rebuild of the projection backfills it. A rebuild also re-inserts every row with a new `updated_at`, so the whole feed reappears once. Consumers are idempotent on `(origin, id)`, so that costs bandwidth, not correctness.

**The two roles meet at `system` and `acting_via`.** `ExternalReference` accepts any lowercase slug, so the importer records `{ system: "chip", … }` through the normal validation, and every import carries `acting_via: feedback_exchange`, which `recorded_via` keeps and the feed leaves out. An imported item is therefore never served back to the peer it came from.

## Verifying a pair

1. On Integrations → Feedback exchange, save the peer's address and both secrets.
2. Press **Test connection**. It sends a signed `GET <base_url>/health` and reports green only when the peer answers `{ "ok": true }`. It works before you enable the exchange. This proves the peer accepts *our* signature.
3. To prove the other direction, have the peer (or you, in a console) sign a request with the inbound secret:

   ```ruby
   ts  = Time.now.to_i.to_s
   sig = FeedbackExchange::Signature.sign(secret: inbound_secret, method: "GET",
           path_with_query: "/api/feedback_exchange/health", body: "", timestamp: ts)
   # curl -H "X-Exchange-Timestamp: #{ts}" -H "X-Exchange-Signature: #{sig}" \
   #   -H "X-Exchange-Consumer: <peer_name>" https://<growthos>/api/feedback_exchange/health
   ```

   A 200 means the pair works. The same request sent again within five minutes returns 401, as does one without the consumer header. A 404 means the exchange is still disabled.
4. To read the feed the same way, sign `GET /api/feedback_exchange/feedback?limit=2` (the query string is part of the signed path), then repeat with `since=<next_cursor>` and a fresh timestamp; only newer rows come back.

## Testing

- Stub the peer with Faraday's test adapter (`Faraday::Adapter::Test::Stubs`) and inject the connection, as the HRIS client test does. `Client#initialize` takes `connection:`.
- To call a real peer on loopback (the Pact mock), pass `host_guard:` to `Client.new` rather than branching `HostGuard` on the environment; the contract tests' guard admits only `127.0.0.1`.
- To prove a request is signed over what was sent, verify it with `Signature.verify` using `env.url.request_uri` and `env.request_body`.
- Signature tests cover the round trip, wrong secret, missing headers, a stale timestamp, a tampered body, a swapped method or path, and the rotation window on both sides of 24 hours.

## Contract tests (Pact)

Consumer-driven contract tests pin the protocol on both sides (decided 22 Oct 2026; the Linear protocol doc's §8). Pact specification **V3**, participants **`growthos`** and **`chip`**, no broker: each app serves its own consumer pact at `/contract`, and the other verifies against it. Chip's `contract/README.md` is the shared reference; this section mirrors it.

| Pact | Written by | Verified by | Lives at |
|---|---|---|---|
| `growthos` → `chip` | `test/contract/chip_consumer_contract.rb`: our real `Client`, `SyncJob` and `Importer` against a Pact mock of Chip | Chip's harness, against its built app | `contract/pacts/growthos-chip.json` (21 interactions), served at our `/contract` |
| `chip` → `growthos` | Chip's consumer tests | `test/contract/chip_provider_contract.rb`, against our app | Chip's `contract/pacts/chip-growthos.json`, served at Chip's `/contract` |

We drive Pact through the `pact-ffi` gem (the Rust core pact-js uses), wrapped thinly in `test/support/pact_contract.rb`; the `pact` gem's DSL is RSpec-only. Both test files sit outside `bin/rails test` (their names do not end in `_test.rb`) because each runs alone, through the rake tasks below.

### Signing, checked across languages

Every request in either pact is signed with the shared secret `pact-test-secret-0123456789abcdef0123456789abcdef` (key id `e6bf4220007d6a9a`) at `1792540800` (2026-10-21T00:00:00Z), so its exact headers are in the pact and the provider's real verifier checks them: no request filter. Because the signature covers the path, query and body:

- request values are literal, never matchers: cursors, limits, ack bodies;
- query keys go alphabetically (`limit` before `since`), the order a Pact verifier replays them in; Faraday sends them that way;
- JSON bodies are compact with keys in the recorded order, since a verifier re-serialises them.

`client_test.rb` pins the query order and the compact ack body, and `signature_test.rb` pins two signatures Chip computed in TypeScript.

### People

Synthetic only, and example hosts only (`chip.example`, `growthos.example`): the pacts are public. `test/integration/feedback_exchange_pact_test.rb` fails on any other email or host in ours.

| Person | Email | HiBob id we hold | Manager |
|---|---|---|---|
| Priya | priya.test@meandu.com | 3141 | marcus |
| Sam | sam.test@meandu.com | 2718 | marcus |
| Marcus | marcus.test@meandu.com | none | none |
| Lena | lena.test@meandu.com | none | marcus |
| Jo | jo.test@meandu.com | none | marcus |

Chip sends made-up HiBob ids for Marcus (1618) and Lena (1414); we match them by email.

### Our states (Chip's pact of us)

`chip_provider_contract.rb` seeds these in a Rack wrapper that exists only in the test, never in `config/routes.rb`. Each state rolls the database back to a savepoint and empties the replay store first, because Chip's pact presents one signature in several interactions. Ids are pinned where Chip's acks name them.

| State | What we seed |
|---|---|
| `the exchange is disabled` | The tenant, exchange off: the feed answers 404 |
| `no feedback is waiting` | People only; a wrong secret gets 401 and `since=not-a-growthos-cursor` 400 |
| `priya.test has given sam.test consented feedback` | `00000000-0000-7000-8000-0000000000b1`, priya → sam |
| `priya.test's feedback to sam.test was edited` | `…b1` with a later `updated_at` and new text |
| `priya.test's feedback to sam.test was withdrawn` | `…b1` withdrawn: served with `text: ""` |
| `lena.test has recorded an observation for jo.test` | `…c1`, `kind: observation` |
| `priya.test has answered sam.test's request in a period` | `…d1`, answering request `…d2` from sam, in cycle `…d3` "Q4 2026" |
| `more feedback is waiting than fits one page` | `…a1`, `…a2`, `…a3` updated at 2026-10-20T23:00, 23:01 and 23:02; with `limit=2`, page 1 is a1 and a2 with `next_cursor` `WyIyMDI2LTEwLTIwVDIzOjAxOjAwLjAwMDAwMFoiLCIwMDAwMDAwMC0wMDAwLTcwMDAtODAwMC0wMDAwMDAwMDAwYTIiXQ`, page 2 is a3 |
| `priya.test's feedback to sam.test can be acknowledged` | As the consented state; the ack answers 204 |

### Chip's states (our pact of Chip)

Chip's paths are `/chip/api/feedback-exchange/feedback`, `…/feedback/deletions` and `…/feedback/ack`. Each test asserts what the puller does as well, since those decisions are the contract too.

| State | Chip serves | We |
|---|---|---|
| `the exchange is disabled` | 404 | stop the run, no retry |
| `no feedback is waiting` | empty feeds, `next_cursor: null` (a wrong secret gets 401) | import nothing (stop on the 401) |
| `priya.test has given sam.test consented feedback` | `…f001`, cursor `ZjF8MjAyNi0xMC0yMFQyMjowMDowMC4xMjM0NTZafDAwMDAwMDAwLTAwMDAtNDAwMC04MDAwLTAwMDAwMDAwZjAwMQ` | import unplaced peer feedback, ack, move the cursor |
| `marcus.test has given sam.test consented feedback` | `…f002`, cursor `ZjF8MjAyNi0xMC0yMFQyMTowMDowMC4xMTExMTFafDAwMDAwMDAwLTAwMDAtNDAwMC04MDAwLTAwMDAwMDAwZjAwMg` | import manager feedback, ack |
| `lena.test has given sam.test feedback without manager consent` | `…f003`, audience `[recipient, hr]`, cursor `ZjF8MjAyNi0xMC0yMFQyMTozMDowMC4yMjIyMjJafDAwMDAwMDAwLTAwMDAtNDAwMC04MDAwLTAwMDAwMDAwZjAwMw` | skip `audience_too_narrow`, no ack |
| `priya.test's feedback to sam.test was edited` | `…f001` updated 23:30:00.654321, cursor `ZjF8MjAyNi0xMC0yMFQyMzozMDowMC42NTQzMjFafDAwMDAwMDAwLTAwMDAtNDAwMC04MDAwLTAwMDAwMDAwZjAwMQ` | update the copy, ack again |
| `priya.test has answered sam.test's request in a period` | `…f004` with request `…f204` and period `…f104`, cursor `ZjF8MjAyNi0xMC0yMFQyMDowMDowMC4zMzMzMzNafDAwMDAwMDAwLTAwMDAtNDAwMC04MDAwLTAwMDAwMDAwZjAwNA` | carry the question, the asker and the period, ack |
| `priya.test's feedback to sam.test was deleted` | deletions feed `{ id: …f005 }`, cursor `ZDF8MjAyNi0xMC0yMFQyMzowMDowMC4wMDAwMDBafDAwMDAwMDAwLTAwMDAtNDAwMC04MDAwLTAwMDAwMDAwZjMwNXwx` | withdraw the copy, store the deletions cursor |
| `priya.test's feedback to sam.test can be acknowledged` | 204 to the ack | send the ack exactly as the sync job builds it |

Chip's ids are `00000000-0000-4000-8000-00000000f00N`. Our acks name `remote_id` (UUIDv5 over a fixed test tenant id) and `remote_url` `https://growthos.example/assessments/<fixed assignment id>`.

### Running it

```bash
bin/rails contract:consumer                     # our consumer tests; rewrites contract/pacts/growthos-chip.json
bin/rails contract:provider PACT_FILE=<path>    # our app against a pact, or a whole /contract response
bin/rails contract:provider                     # ... against Chip's deployed pact (FEEDBACK_EXCHANGE_PEER_CONTRACT_URL)
FRESH=1 bin/rails contract:fetch_peer           # fetch Chip's /contract into tmp/contract now
bin/rails contract:check_change                 # our pact against our deployed one (FEEDBACK_EXCHANGE_OWN_CONTRACT_URL)
```

Chip's pact is cached in `tmp/contract/chip.json` and refetched after a day. A failed fetch falls back to the cached copy with a warning and fails only with no copy; a 404 with no copy (Chip has not published) or an unset URL passes with a warning. The verifier prints its own per-interaction report. Run one consumer test with `bin/rails test test/contract/chip_consumer_contract.rb -n /…/`: it writes to `tmp/pact/consumer`, never the committed file.

CI: `ci.yml`'s `contract` job runs the consumer tests, fails if the committed pact differs from what they wrote, then verifies the branch against Chip's deployed pact. `contract.yml` re-verifies nightly with a fresh fetch and holds the `contract-change` gate. See [.github/AGENTS.md](../../.github/AGENTS.md).

### Changing a pact

1. Change the consumer test (and the code), run `bin/rails contract:consumer`, and commit `contract/pacts/growthos-chip.json` with the change.
   A `pact-ffi` upgrade rewrites the pact's metadata versions, so its PR fails the `contract` job until someone runs `bin/rails contract:consumer` and commits the result; Dependabot cannot.
2. A changed pact changes what Chip must honour. Run Chip's harness against it (`npm run contract:provider -- --pact-file <path>` in Chip's repo), link the passing run in the PR and add the `contract-change` label; without it the `contract-change` check fails. A Pact upgrade that only moves metadata versions is not a change.
3. A new state is agreed with Chip first, then gets a row here and in Chip's README, and a seeder in `chip_provider_contract.rb` (ours) or a test using it (theirs). `feedback_exchange_pact_test.rb` lists the states we may use.
4. Chip's pact changing ours to honour arrives the other way round: its PR links a run of `bin/rails contract:provider PACT_FILE=<its file>`.
5. A breaking protocol change is `v2`, not a pact edit.

## Gotchas

- `base_url` must carry the peer's prefix. A client pointed at the bare host signs a path the peer never serves.
- Sign what Faraday sends. Hand-building a query string can order or encode it differently from the wire, and the peer's check then fails with a bare 401.
- **Two identical requests within one second share a signature**, and the replay guard refuses the second. Space retries by more than a second; do not read that 401 as a wrong secret.
- **Write settings through `Tenant#update_feedback_exchange!`.** It locks and reloads the row first. Anything that writes `feedback_exchange_config` from a job (the cursors, `last_synced_at`) must do the same, or an admin saving the form overwrites it with stale values, and the reverse.
- **A test that imports must give the importer a tenant with the exchange set up** (`test/support/feedback_exchange_records.rb` has `connect_feedback_exchange` and `exchange_record`, built on `test/fixtures/files/feedback_exchange/record.json`).
- **The importer dispatches command handlers itself, so it wraps them in `AuditMetadata.wrap_event_store`.** `AuditMetadata.with` alone only sets the thread-local; outside an Operation nothing copies it onto the events, and `acting_via` would be missing.
