# Feedback Exchange

> Read this when: touching anything under `app/integrations/feedback_exchange/`, `app/controllers/feedback_exchange/`, the signed-request concern, the exchange settings page, or a feature that sends feedback to, or takes it from, another feedback system. The contract is [the protocol](../notes/feedback-exchange-protocol.md); what GrowthOS builds on it is [the plan](../notes/feedback-integration-plan.md).

## What it is

Two feedback systems each serve the feedback given in them and pull the other's. GrowthOS plays both roles under one namespace, `FeedbackExchange`. The first peer is Chip. Nothing is pushed: a consumer pulls on its own schedule, so a missed run costs nothing.

Phase 0 (this guide's first content) is the foundation: config, secrets, signing, the client, the verifier, the health endpoint and the admin card. Nothing calls the client yet. The importer, the producer feed and suggestions land on top of it.

## Configuration

`Tenant#feedback_exchange_config` is a `FeedbackExchangeConfig` (StoreModel, JSONB), shaped like `HrisConfig`.

| Field | Meaning |
|---|---|
| `provider` | `exchange` for a protocol peer |
| `peer_name` | A slug, `chip`. It becomes `origin` and `external_reference.system` |
| `base_url` | The peer's exchange root **including its path prefix**, e.g. `https://chip.example.com/api/feedback-exchange`. https only; http is accepted in development |
| `enabled` | Off by default. While off, inbound requests get 404 and nothing is pulled |
| `import_kinds` / `export_kinds` | Which `kind`s cross. Empty `import_kinds` means everything |
| `cursor`, `deletions_cursor`, `last_synced_at` | Consumer state |
| `suggestions_enabled` | Placement suggestions, off by default |

`peer_name` and `base_url` are required once `enabled`. One peer per tenant for now.

An admin edits `base_url`, `peer_name`, `enabled` and the secrets on **Integrations → Feedback exchange**. Config edits are web-only on purpose: the page holds signing secrets, which must not travel through an MCP client. MCP gets the read `integrations_feedback_exchange_status`, which reports state and whether each secret and cursor is present, never a value.

## Secrets

`Tenant#feedback_exchange_credentials` is an encrypted JSON column, like `hris_credentials`:

```json
{ "outbound_secret": "…", "inbound_secret": "…",
  "previous_inbound_secret": "…", "previous_rotated_at": "2026-10-20T09:00:00Z" }
```

- **Outbound** signs what we send. The peer holds the same value as its *inbound* secret. **Inbound** verifies what the peer sends.
- Read them through `Tenant#feedback_exchange_secrets`, a `FeedbackExchangeSecrets` whose `inspect` and `to_s` print only whether a value is set. Do not read the raw column in new code, and never log a secret. The parameter filter already covers `*secret*`.
- The settings form never echoes a secret. A blank field keeps the stored value.
- **Rotation.** Saving a different inbound secret moves the old one to `previous_inbound_secret` and stamps `previous_rotated_at`. The verifier accepts the previous secret for 24 hours, so the two sides rotate without a coordinated deploy. Rotating the *outbound* secret has no window: change the peer's inbound value first, then ours.
- Use 32+ random bytes: `SecureRandom.hex(32)`.

## Signing (protocol §6)

`FeedbackExchange::Signature` is pure Ruby on ActiveSupport. It both signs and verifies.

```
X-Exchange-Timestamp: <unix seconds>
X-Exchange-Signature: v1=<hex HMAC-SHA256(secret, signing_string)>
signing_string = "v1:" + timestamp + ":" + METHOD + ":" + path_with_query + ":" + sha256_hex(raw_body)
```

- `path_with_query` is the path **as sent**, query string included and in the order sent. Sign what goes on the wire: `FeedbackExchange::Client` takes it from Faraday's own URL builder rather than rebuilding it.
- `raw_body` is the bytes as sent, empty for a GET. The verifier reads `request.raw_post`, never re-serialised params.
- A timestamp more than 300 s from now is refused. The compare is constant-time and checks every accepted secret without short-circuiting.
- **Replays.** The verifier claims each accepted signature in `Rails.cache` for the 300 s window, so a captured request cannot be sent twice. The test environment uses a null cache store, so a test that exercises a replay must swap in a `MemoryStore`.

## The client

`FeedbackExchange::Client.for(tenant)` is Faraday with per-instance secrets and no global state, as `Hris::Hibob::Client` is. Methods: `feedback(since:, limit:)`, `deletions(since:, limit:)`, `ack(items)`, `health`. Every request carries `X-Exchange-Consumer: growthos` and a fresh signature.

It does **not** retry. The sync job owns retries, from the error class:

| Error | When | Job should |
|---|---|---|
| `AuthenticationError` | 401 | discard and tell a human |
| `RateLimitError` (`retry_after`) | 429 | retry after the stated delay |
| `ApiError` (`status`, nil if unreachable) | 5xx, other 4xx, no answer, a non-JSON body | retry with backoff |

## Inbound requests

`FeedbackExchangeSignedRequest` is the trust boundary, modelled on `SlackSignedRequest`. A controller inherits `ActionController::Base`, includes it and adds `around_action :authenticate_feedback_exchange_request!`. The signature is the only credential, so there is no Devise, no CSRF and no Pundit `authorize`.

The concern finds the tenant whose inbound secret (or previous one, inside the window) verifies the request, claims the signature, and runs the action inside `ActsAsTenant.with_tenant`. Answers:

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
- The Integrations card's counts section is a placeholder until the importer ships.
