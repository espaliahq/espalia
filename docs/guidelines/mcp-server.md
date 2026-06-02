# MCP Server — Design & Architecture

This document captures the design decisions, conventions, and hard-won
lessons from building GrowthOS's MCP (Model Context Protocol) server.
Consult this before adding new MCP tools, changing tool shapes, or
touching anything under `app/operations/`, `app/services/mcp/`,
`app/controllers/mcp/`, `app/models/mcp/`, `app/jobs/mcp/`, or
`app/views/mcp/`.

> **Top-level rule (from root CLAUDE.md):** every new user-facing
> read or write surface must explicitly consider MCP coverage. The
> default is to build it as an `Operations::*` class so the web and
> MCP server share one implementation; opting out requires an
> explicit reason in the PR.

> **Related design docs:** [event-sourcing.md](event-sourcing.md) for how
> Operations interact with the event store; [authorization.md](authorization.md)
> for the `AuthorizationContext` chain Operations reuse.

## Overview

GrowthOS exposes a single MCP endpoint at `POST /mcp` that speaks
JSON-RPC 2.0 over the Streamable HTTP transport. An MCP client
(Claude Code, Claude Desktop, etc.) connects with `{ "type":
"streamable-http", "url": "https://app/mcp" }` and is expected to do
OAuth + Dynamic Client Registration on its own — no human paste of
client_ids required.

```
MCP client → POST /mcp (Bearer token)
                ↓
          Mcp::ServerController
                ↓
          Mcp::RequestHandler (JSON-RPC dispatch)
                ↓
          tools/call → Operations::* (via Mcp::OperationToTool descriptor)
          resources/read → same Operations (via Mcp::ResourceRegistry)
```

The auth surface lives at `/oauth/*` (Doorkeeper, PKCE-only) with
discovery docs at `/.well-known/oauth-{protected-resource,authorization-server}`
and Dynamic Client Registration at `POST /oauth/register`. See
[authorization.md](authorization.md) for the identity chain Operations
reuse.

## Architecture

Four layers, each with a single responsibility:

```
app/operations/operations/   ← business logic (also consumed by web controllers)
        ↑
app/services/mcp/            ← protocol plumbing (registry, serializer, dispatcher)
        ↑
app/controllers/mcp/         ← transport (POST /mcp, OAuth approval reviewer)
        ↑
config/initializers/         ← Doorkeeper + Rack::Attack wiring
config/routes.rb             ← `/mcp`, `/oauth/*`, `/.well-known/*`
```

**Operations are the shared write surface.** Web controllers and the
MCP server both go through `Operations::*` — never direct
`*::CommandHandler` calls. This is the load-bearing invariant for
parity between the two interfaces and is enforced by the
`GrowthOs/ControllersMustUseOperations` RuboCop cop. Existing controllers
pre-dating the layer are grandfathered via `.rubocop.yml`'s `Exclude:`
list and migrated one PR at a time.

## Key Design Decisions

### 1. Operations layer as the single source of truth

Every user-facing operation — web action or MCP tool — runs through an
`Operations::Base` subclass declaring `description`, `category`,
`approval`, parameters, `policy_check`, and `perform`. Controllers,
the MCP request handler, and in-app approval execution all dispatch
through the same class. Policy lives there, not in the controller
(though controllers still call `authorize` for defense in depth on web
flows). The MCP tool descriptor (`Mcp::OperationToTool.call`) and the
shared registry (`Operations::Registry`) are derived from these classes
at boot.

### 2. Three approval categories

| Approval | When | Examples |
|---|---|---|
| `:none` | Reads, ambient ops | `frameworks_list`, `assessments_get`, `system_whoami` |
| `:mcp_client` | Writes the MCP client's standard prompt is sufficient friction for | `assessments_rate_self`, `assessments_record_evidence` (additive, no permissions changed) |
| `:in_app` | Writes that need user confirmation in the web UI (irreversible, permission-changing, tenant settings) | `frameworks_publish_version`, `assessment_cycles_close`, `frameworks_add_collaborator` (when shipped) |

`:in_app` operations don't execute inside MCP; the request handler
persists a `Mcp::PendingApproval` row and returns a URL the user opens
in their browser to confirm. The deferred Operation runs in
`Mcp::ApprovalsController#approve` under a freshly-rebuilt
`AuthorizationContext` — Pundit re-applies, so role changes between
submission and approval are honored.

### 3. Incremental disclosure (no context poisoning)

Big payloads ruin LLM context. The disclosure rule across read tools:

**Each tool returns ID + name of children one level deeper — no
further.** A framework returns role families with their roles, and
categories with their capabilities (just id + name). Inline expectations
and illustrations are NOT included. Drilling further requires a follow-
up tool call (`frameworks_capability_get`).

A real framework is ~5–15KB at this depth instead of 50KB+ flat.

### 4. Shape parity via shared serializers

Assessment payloads are **strict supersets** of framework payloads —
same keys, same nesting, plus an overlay. An LLM that learned
`frameworks_get`'s shape needs zero new schema knowledge for
`assessments_get`; same with `*_capability_get`.

The mechanism: `Mcp::FrameworkSerializer` is the single source of
truth. Framework Operations call it directly; Assessment Operations
call it then `merge` overlay fields. Shape parity is asserted by
explicit tests in `test/operations/assessments/*_test.rb`.

### 5. Uniform input shape across related write tools

The three rating tools (`assessments_rate_self`,
`assessments_rate_as_manager`, `assessments_align`) take **identical
inputs** (`assignment_id` + `capability_stable_id` + `level_ordinal` +
`frequency` + optional `comment`/`rationale`) and return **identical
outputs** (`{ framework_id, capability_stable_id, level_ordinal,
cycle_id, frequency }`). Differentiation is purely the Pundit policy
they enforce. Pattern: when adding a write tool that mirrors another,
match its input/output shape; let policy do the gating.

### 6. Tenant-bound tokens

OAuth tokens are bound to **one tenant** at consent time. Users who
belong to multiple tenants re-authorise to switch. Implementation:

- `Doorkeeper.config.custom_access_token_attributes [:tenant_id]`
- Custom `Oauth::AuthorizationsController` shows a workspace picker
  in the consent screen; the chosen `tenant_id` rides on the POST,
  gets persisted on the `AccessGrant`, and is copied to the
  `AccessToken` at the `/oauth/token` exchange (automatic via
  Doorkeeper's machinery once declared as a custom attribute).
- `Mcp::ServerController#set_tenant_from_token` re-verifies that the
  user STILL has a `TenantUser` for the token's tenant on every
  request; if revoked, fail closed with `:membership_revoked` rather
  than processing against an empty `AuthorizationContext`.

### 7. Discovery + DCR for self-onboarding

A fresh CLI install gets a working OAuth flow from just `url:
http://localhost:3000/mcp` — no manual app registration. The chain:

```
POST /mcp → 401 + WWW-Authenticate: Bearer resource_metadata="<url>"
GET /.well-known/oauth-protected-resource    (RFC 9728)
GET /.well-known/oauth-authorization-server  (RFC 8414)
POST /oauth/register                          (RFC 7591 — Dynamic Client Registration)
GET /oauth/authorize (browser-side, consent screen with tenant picker)
POST /oauth/token   (PKCE code exchange)
POST /mcp (Bearer)
```

DCR is throttled to 30/hr/IP by `config/initializers/rack_attack.rb`
(prod only — disabled in dev/test to avoid surprising contributors).
Stale DCR-registered clients are auto-pruned daily by
`Mcp::PruneStaleClientsJob` (anything 30+ days without token activity).

### 8. Auth context flow

The token's `tenant_id` and `resource_owner_id` drive
`Mcp::ServerController#authorization_context`, which builds the same
`AuthorizationContext(user:, tenant_user:, person:)` value object that
web controllers' `pundit_user` produces. Operations and policies see
identical inputs whether called from a controller or from MCP —
that's what makes shape and behaviour parity tractable.

### 9. Audit metadata stamps every write

Every event published by an Operation carries metadata identifying who
triggered it and via what surface: `acting_via: "web" | "mcp" | "hris"`
and (for MCP) `client_application_id`. Mechanism:

- `AuditMetadata.with(acting_via:, client_application_id:)` sets a
  thread-local for the duration of a block.
- `ApplicationController` uses `around_action :wrap_with_audit_metadata`
  for `:web`; `Mcp::ServerController` wraps its dispatch with `:mcp +
  client_application_id`; the HiBob adapter wraps its sync loop with
  `:hris`.
- `Operations::Base#call` wraps `perform` with
  `AuditMetadata.wrap_event_store` — the metadata flows onto any event
  the underlying command handler publishes.
- **Symbol values are stringified at the event-store boundary** because
  `ruby_event_store::Metadata` only accepts
  `String/Integer/Float/Date/Time/Bool/nil/Hash/Array`. Thread-local
  keeps Symbols for caller ergonomics; the wrap converts.

### 10. Resources mirror tools

`framework://<id>` and `assessment://<id>` MCP resources delegate to
the same `Operations::Frameworks::Get` and `Operations::Assessments::Get`
the tools use. There is one payload shape per node type, regardless
of whether the LLM fetches via tool or resource. `resources/list`
enumerates what's visible to the calling context (subject to acts_as_tenant
+ Pundit). Resources are for pinned context; tools are for actions —
keep that line clear if expanding either surface.

### 11. Drift prevention

Two automated guards:

- **`Operations::Registry` hygiene** — `test/operations/registry_test.rb`
  asserts no anonymous subclasses, every op has a description, valid
  category + approval, unique tool name.
- **Tool registry snapshot** — `test/mcp/tool_registry_snapshot_test.rb`
  pins the full tool surface (name + description + JSON schema +
  annotations). Any add/remove/rename produces a diff in the PR that
  introduces it; intentional changes update the snapshot in the same
  commit.

For controllers, the `GrowthOs/ControllersMustUseOperations` cop
prevents direct `*::CommandHandler.new` calls; grandfathered
controllers are listed in `.rubocop.yml`'s `Exclude:` (remove the
entry when porting one).

### 12. CLI parity tests are real but constrained

`test/integration/mcp_claude_cli_test.rb` drives the actual `claude`
CLI as a subprocess against a Capybara-booted Puma instance. This is
the only test that proves the full transport (auth → JSON-RPC → tool
dispatch) works against a real client. Constraints worth knowing:

- The CLI test is non-deterministic (an LLM is in the loop). Assert
  on test-local UUIDs the CLI can't possibly hallucinate from
  training, never on values that might be in user memory (email,
  name, etc).
- Use `--no-session-persistence` to avoid littering the user's
  `/resume` picker.
- The CLI is required in CI (`.github/workflows/ci.yml` installs
  `@anthropic-ai/claude-code`) and in the devcontainer (`postCreateCommand`).
  The harness `flunk`s if missing — silent skips hide parity erosion.
- The CLI test runs in a dedicated `mcp-cli-test` CI job so the main
  `test` job doesn't pay for Node + the CLI install or the LLM
  round-trip. The main job sets `SKIP_MCP_CLI_TEST=1`, which is the
  ONLY supported skip path — the binary check still `flunk`s for any
  other invocation so missing parity coverage outside the carve-out
  stays loud.

## Hard-Won Lessons

### 1. RES Metadata rejects Symbol values

`ruby_event_store::Metadata#[]=` raises `ArgumentError` (with the
unhelpful message `"ArgumentError"`) when handed a Symbol value. The
allowed types are `String/Integer/Float/Date/Time/Bool/nil/Hash/Array`.
`AuditMetadata.wrap_event_store` stringifies Symbols just before
calling `event_store.with_metadata` so the thread-local API stays
ergonomic.

### 2. Doorkeeper models bypass ApplicationRecord

`Doorkeeper::Application` / `AccessGrant` / `AccessToken` inherit
`Doorkeeper::ApplicationModel`, not our `ApplicationRecord`, so the
`before_create :assign_uuid_v7_id` callback never fires and inserts
fail with `NULL` PK violations. The fix: `Mcp::Application` /
`Mcp::AccessGrant` / `Mcp::AccessToken` subclasses inherit
`ApplicationRecord` AND include the Doorkeeper mixin, configured via
`application_class`/`access_grant_class`/`access_token_class` in
`config/initializers/doorkeeper.rb`. Tests must reference the
`Mcp::*` subclasses, NOT `Doorkeeper::*` directly.

### 3. `--allowed-tools <tools...>` swallows positional args

`claude --print "prompt" --allowed-tools "mcp__growth_os__*"`:
the variadic option consumes "prompt" as part of its tool list, then
the CLI errors with `"Input must be provided either through stdin
or as a prompt argument"`. Fix: put the prompt FIRST (right after the
binary), flags afterwards.

### 4. Hash and Array parameters need explicit TYPE_MAPPING

`Mcp::OperationToTool` maps Ruby parameter types to JSON Schema
primitives. Without `Hash => "object"` (and `Array => "array"`)
entries, a `parameter :external_reference, Hash` advertises itself
as `type: "string"` — confusing for any client trying to validate input.

### 5. Capability lookup must be scoped to the framework

`FrameworkState::Capability.find_by!(capability_id: ...)` is wrong even
inside an acts_as_tenant scope: a single tenant can hold multiple
frameworks, and an attacker authorized for framework A could request a
`capability_id` belonging to framework B. Always join through
`framework_capability_categories.framework_id` to scope the lookup to
the authorized framework. Same applies for any "look up child X under
parent Y" pattern.

### 6. CSRF protection 422s POSTs before Doorkeeper sees them

The `Mcp::ServerController` POST endpoint inherits `ActionController::Base`
which enables Rails' default forgery protection. CSRF rejects the
request with 422 before `doorkeeper_authorize!` runs, so the client
never sees the proper 401 + `WWW-Authenticate` flow. `skip_forgery_protection`
on the controller is required.

### 7. OAuth issuer must be a stable configured value, not derived

Behind a proxy / load balancer, `request.base_url` flips based on
`X-Forwarded-*` headers — and RFC 8414 §2 requires the issuer to be
the same exact-match string a client validated at discovery time.
`Mcp::WellKnownController` reads
`Rails.application.config.x.oauth_issuer` (set from `OAUTH_ISSUER` env
var in production) and only falls back to `request.base_url` in dev
where the canonical URL is the dev server itself.

### 8. Symbols in `AuditMetadata` thread-local — keep them

The thread-local stores `acting_via: :web` (Symbol) for caller
ergonomics. Tests that read `AuditMetadata.current[:acting_via]` see
the Symbol; tests that read it off the event_store metadata see
`"web"` (String). Don't try to unify these — the boundary is the
explicit `serialize` step in `AuditMetadata.wrap_event_store`.

### 9. Tool descriptors are snake_cased from class names

`Operations::System::Whoami` → `"system_whoami"`. The snake_case
rules are camelCase-aware (`RateAsManager` → `rate_as_manager`).
Naming an Operation matters: it ends up as the user-visible tool name
in MCP clients. Use the same noun-verb structure as the existing
operations (`assessments_rate_self`, `frameworks_capability_get`).

### 10. Operations register themselves; the registry eager-loads on
first read

`Operations::Base.inherited` self-registers concrete subclasses (named
classes only — anonymous test subclasses are filtered). `Operations::Registry.all`
calls `eager_load_dir` on the operations subtree on first read in
dev/test, guarded by a mutex to avoid the inherited callback re-entering
during the load. In production everything is eager-loaded at boot so
the registry is complete the moment `Registry.all` is first called.

### 11. CLI tests assert on test-local UUIDs, never user-visible identity

An earlier version of the CLI parity test asked the LLM for the user's
email and asserted on `@user.email`. The CLI's LLM answered from auto-memory
without invoking the tool — and the test passed. Replace such assertions
with values that can't possibly be in the CLI's context: the tenant's
freshly-minted UUID, an evidence_id from a real call, etc.

### 12. Dynamic Client Registration must be pruned

Every fresh CLI install creates an `oauth_applications` row via DCR.
Without `Mcp::PruneStaleClientsJob`, the table grows unbounded over
time. The prune job is scoped to **DCR-registered apps only**
(`dynamically_registered_at IS NOT NULL`); admin-registered apps are
never auto-deleted. When adding fields or behaviours to `oauth_applications`,
think about whether they should also affect the stale-DCR query.

## Approval declaration cheat sheet

When declaring `approval` on a new Operation, consult this table:

| Question | If yes → |
|---|---|
| Read-only (no event published, no state mutation)? | `:none` |
| Affects only the caller's own data, no permissions changed? | `:mcp_client` |
| Cross-person write but routine (e.g. manager rating direct report)? | `:mcp_client` |
| Records additive context (evidence, comments)? | `:mcp_client` |
| Changes someone else's permissions (grant/revoke collaborator)? | `:in_app` |
| Tenant or billing settings? | `:in_app` |
| Irreversible event-sourced operation (publish, close, lock)? | `:in_app` |
| Bulk operation affecting many records in one call? | `:in_app` |

When in doubt, prefer `:in_app` — adding an extra confirmation step is
recoverable; an MCP agent loop running unintended writes is not.

## File Reference

| File | Purpose |
|------|---------|
| **Operations layer (shared with web)** | |
| `app/operations/operations.rb` | Module declaration |
| `app/operations/operations/base.rb` | DSL + `#call` pipeline + `authorize` helper |
| `app/operations/operations/registry.rb` | Self-registration + lazy eager-load |
| `app/operations/operations/<domain>/<noun>.rb` | Concrete Operations (one per MCP tool) |
| **MCP protocol plumbing** | |
| `app/services/mcp/operation_to_tool.rb` | Operation class → MCP tool descriptor |
| `app/services/mcp/request_handler.rb` | JSON-RPC dispatch (initialize, tools/*, resources/*) |
| `app/services/mcp/framework_serializer.rb` | Shared shape source-of-truth |
| `app/services/mcp/resource_registry.rb` | `framework://` / `assessment://` resource list + read |
| `app/services/audit_metadata.rb` | Thread-local audit context, shared with web/HRIS |
| **MCP transport** | |
| `app/controllers/mcp/server_controller.rb` | `POST /mcp` — bearer auth, tenant resolution, dispatch |
| `app/controllers/mcp/well_known_controller.rb` | OAuth discovery docs (RFC 8414 + 9728) |
| `app/controllers/mcp/client_registrations_controller.rb` | Dynamic Client Registration (RFC 7591) |
| `app/controllers/mcp/approvals_controller.rb` | In-app approval review UI for `:in_app` ops |
| `app/views/mcp/approvals/show_view.rb` | Phlex view for the approval page |
| **User-facing settings** | |
| `app/controllers/settings/connected_clients_controller.rb` | "AI assistants" page — connect instructions + list/revoke connected clients |
| `app/views/settings/connected_clients/index_view.rb` | Connect steps (Claude Code / Claude.ai & Desktop / ChatGPT / Codex) with copy-to-clipboard + connected-token table. Linked from the user dropdown (`Kit::UserMenu`). |
| `app/javascript/controllers/clipboard_controller.js` | Copy-to-clipboard for the server URL / CLI commands on the setup page |
| **OAuth + Doorkeeper subclassing** | |
| `app/controllers/oauth/authorizations_controller.rb` | Custom consent screen with tenant picker |
| `app/views/oauth/authorizations_view.rb` | Consent screen Phlex view |
| `app/models/mcp/application.rb` | Doorkeeper application → ApplicationRecord |
| `app/models/mcp/access_grant.rb` | Doorkeeper grant → ApplicationRecord |
| `app/models/mcp/access_token.rb` | Doorkeeper token → ApplicationRecord |
| `app/models/mcp/pending_approval.rb` | Persisted in-app approval handoff |
| `app/jobs/mcp/prune_stale_clients_job.rb` | Daily DCR-row cleanup |
| `config/initializers/doorkeeper.rb` | PKCE-only OAuth provider config |
| `config/initializers/rack_attack.rb` | DCR rate limit (prod only) |
| `config/initializers/audit_metadata.rb` | (none — wired via ApplicationController + Mcp::ServerController) |
| **Routes** | |
| `config/routes.rb` | `/mcp`, `/oauth/*`, `/.well-known/*`, `/mcp/approvals/*` |
| **Tests** | |
| `test/operations/registry_test.rb` | Registry hygiene |
| `test/mcp/tool_registry_snapshot_test.rb` | Tool surface snapshot (drift guard) |
| `test/integration/mcp_server_test.rb` | JSON-RPC unit coverage of tools/* and resources/* |
| `test/integration/mcp_discovery_test.rb` | Well-known docs + DCR + WWW-Authenticate header |
| `test/integration/mcp_in_app_approval_test.rb` | Pending approval lifecycle |
| `test/integration/oauth_pkce_flow_test.rb` | Full PKCE flow with consent + tenant binding |
| `test/integration/mcp_claude_cli_test.rb` | End-to-end with real `claude` CLI subprocess |
| `test/jobs/mcp/prune_stale_clients_job_test.rb` | Prune scope + safety |
| **Lint** | |
| `lib/rubocop/cop/growth_os/controllers_must_use_operations.rb` | Controllers must dispatch through Operations |

## Keeping This Document Current

This document must be updated whenever changes are made to MCP server
architecture, tool conventions, the OAuth surface, or the
disclosure / shape-parity rules. Specifically:

- **New design decisions** — add to "Key Design Decisions" with the
  rationale.
- **Bug fixes that revealed non-obvious behaviour** — add to "Hard-Won
  Lessons". Each entry should explain the surprise, not just the fix.
- **New files in any of the MCP-touched directories** — update the
  "File Reference" table.
- **Approval-routing rule changes** — update the "Approval declaration
  cheat sheet".

If a lesson or decision is superseded, update or remove the old entry
rather than appending a contradiction.
