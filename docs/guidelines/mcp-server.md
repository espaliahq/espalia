# MCP Server — Design & Architecture

This document captures the design decisions, conventions, and hard-won
lessons from building GrowthOS's MCP (Model Context Protocol) server.
Consult this before adding new MCP tools, changing tool shapes, or
touching anything under `app/operations/`, `app/services/mcp/`,
`app/controllers/mcp/`, `app/models/mcp/`, `app/jobs/mcp/`, or
`app/views/mcp/`.

> **Top-level rule (from root AGENTS.md):** every new user-facing
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

The auth surface lives at `/oauth/*` (Doorkeeper, PKCE + refresh-token,
public clients) with discovery docs at
`/.well-known/oauth-{protected-resource,authorization-server}` and Dynamic
Client Registration at `POST /oauth/register`. See
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
| `:in_app` | Writes that need user confirmation in the web UI (irreversible, permission-changing, tenant settings) | `frameworks_publish_version`, `assessment_cycles_close`, `frameworks_add_collaborator` |

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

The suggestion surface follows the same drill-down: `frameworks_recent_activity`
surfaces suggestion entries (with `suggestion_id`s), and
`frameworks_suggestion_get` is the drill-in — one suggestion's proposal,
resolution, and discussion thread (top-level comments with replies nested one
level, the `assessments_comments_list` shape).

The same rule shapes the assessment drill-down. `assessments_capability_get`
returns the capability detail plus a compact per-level **ratings** overlay
— it deliberately does NOT inline evidence bodies or comment threads (both
can be large and would poison context). Reaching those is one more
follow-up call: `assessments_evidence_list` and `assessments_comments_list`,
each scoped to a capability (optionally one level). So the read traversal is
`assessments_mine → assessments_get → assessments_capability_get →
{assessments_evidence_list, assessments_comments_list}`. Both leaf tools are
`:none`-approval reads gated by the same view policy as the rest of the
assessment surface (`EvidencePolicy#index?` / `PersonDevelopmentCommentPolicy#index?`
— assessee + manager chain + active rating delegate + tenant admin; peers
are denied), return active rows only (withdrawn evidence / removed links /
soft-deleted comments are omitted), and accept either a `capability_id` or a
cross-version `stable_id` in the `capability_stable_id` argument.

**Scores ride the same drill-down, at the altitude the caller is already
at.** `assessments_get` carries the whole assessment's number plus a
per-category roll-up; `assessments_capability_get` carries that one
capability's. Both come from {Assessments::ScoreSummary}, which runs the
web's own `MatrixDataBuilder`, so an agent cannot report a number the
person's screen disagrees with. Three rules a payload of bare numbers
needs and a screen does not:

- **The scale travels with the score.** Every payload carries `scale:` —
  the unit, the assessed level's code, the next level's, and a sentence
  saying 100 is meeting the assessed level and 200 is demonstrating the
  next. A client that reads `132` with no scale invents one.
- **The parts travel with the net.** `components:` splits the number into
  what is demonstrated at the assessed level, what is earned above it, and
  what is still missing below — the gloss the hero renders, in fields.
- **The thresholds are the framework's, not assumed.** A tenant can move
  any of the three bands, so `thresholds:` ships with the score rather
  than leaving a client to hard-code 80/95/150.
- **The screen's honesty gates travel too.** Every altitude reports
  `scored:`, and when it is false the numbers are nil with an
  `unscored_reason` — `coverage_below_threshold` (the hero's "Rate
  yourself to see your score" and the category header's "score unlocks at
  2"), `not_rated_at_assessed_level` (a card's "Not rated"),
  `no_expectation_at_assessed_level`, or
  `assignment_structure_unavailable` when the assignment's role or level
  record is gone. Alignment is exempt from the coverage gate exactly as
  the hero is. Without this an agent reads a number off an assessment
  nobody has started and reports it as a verdict — the failure the whole
  surface exists to avoid.

Note the ceiling is **not** fixed at 200: the over-performance cap decides
how many bands sit above the assessed level, so a cap of 2 tops out at 300.
And 200 is not promotion readiness — that is evaluated separately at the
next level and needs the meeting threshold plus nothing held there (no
blocked capability, none unrated). The tool descriptions say
"level-independent scale" for both reasons.

**`blocked` and `unrated` are separate lists.** Only a rating can block
([#485](https://github.com/mr-yum/growth-os/issues/485)): a capability nobody
has rated is never in `blocked`. It still holds the state, so `scoring.unrated`
names it, and an agent explaining a Progressing state reads both.

A capability's score also carries `weight` and `required` — the two binding
facts its card wears as chips ([#431](https://github.com/mr-yum/growth-os/issues/431)) — so an agent can explain a score the
person can see the reason for. `required` is the resolved tolerance
(binding, then category, then framework default) being 0, exactly what the
card shows; the raw per-binding tolerance stays on the framework payload.

**A lens says it is one.** `assessments_get` and `assessments_capability_get`
take `as_role_id` / `as_level_ordinal` to read the same ratings against another
role or level (ADR-22). The score then carries `lens: { role_id, role_code,
level_ordinal, home }` beside `scale:` (`home: false` off the record), and each
capability carries `in_role: { home, lens }` — so an agent can't report a PM3
number as the E3 assessment. Every honesty gate holds under a lens, and the
per-cell disclosure is the web's: the assessee never receives a manager rating
on a cell until alignment has started against a role that reads it. All three
rating tools take `as_role_id` to rate a cell the lens role reads, and refuse a
cell a started alignment froze (the error names the role).

**Alignment is per role, and says so.** `assessments_start_alignment` /
`assessments_complete_alignment` (`:in_app` — starting discloses the manager's
ratings and freezes both parties'; completing formalises a record) and
`assessments_reopen_alignment` take the same `as_role_id` / `as_level_ordinal`
pair as the read tools, default to the home role, and return the role
(`role_id, role_code, level_ordinal, home, status`) with the cycle. The
completion gate is the role's own, and its refusal names how many cells remain.
`assessments_get` lists every alignment started this cycle under
`current_cycle.alignments: [{ role_id, role_code, level_ordinal, status, home }]`
without needing a lens, so an agent knows a PM3 conversation exists.

The per-category roll-up also carries `rated_at_assessed_level` /
`total_at_assessed_level`, the same coverage counts the screen shows, so an
agent can tell a low score from a barely-rated one. The overall `coverage`
adds `to_confirm_at_assessed_level`: carried values count as rated but are
not this cycle's until confirmed, and without the count an agent asked "how
do I finish?" could only answer "wait for alignment" (#480).
`assessments_confirm_carried_ratings` confirms them. Perspective is resolved
by the shared `Assessments::ViewerContext`, so the self-assessment privacy
rule holds identically on both surfaces: before alignment starts, an
assessee's payload is built from self ratings alone.

Evidence and comments are full **read + write** surfaces over MCP, not
read-only feeds. Beyond recording/linking evidence, an agent can edit and
withdraw it (`assessments_update_evidence`, `assessments_withdraw_evidence`)
and run the comment conversation end to end (`assessments_post_comment`,
`assessments_edit_comment`, `assessments_delete_comment`). All five are
`:write`/`:mcp_client`, dispatch through the same command handler and Pundit
policies as the web controllers (author-only edits; author + admin
withdraw/delete; view-gated posting), and model their soft deletes the same
way (withdrawn evidence / `status: "deleted"` comments stay for audit). The
guiding rule when completing a surface: if the web can do it, the MCP write
tool should exist too — a half-exposed feature (write with no read, or
create with no edit/withdraw) is the gap to avoid.

**Feedback can be volunteered, not only requested.** `assessments_feedback_recipients`
is the directory a peer needs: people with a framework assignment, by name
or email, or the caller's manager, peers and reports with no query, each row
carrying the `assignment_id` for `assessments_record_evidence`. That write
takes the cell optionally — the schema's `dependentRequired` says capability,
level and valence come together or not at all, and `additional_links` need a
first link — and an item recorded with no cell is **unplaced**: the recipient
or their manager places it later with `assessments_add_evidence_link`.
`assessments_evidence_list` with no capability lists the unplaced items
(`unplaced: true`). A peer still cannot read the assessment; the directory is
the whole of what they see ([assessments/evidence.md → Proactive feedback](assessments/evidence.md)).

**Placement suggestions are read and decided, never generated, over MCP.**
`assessments_evidence_suggestions_list` (`:none`) lists the pending
suggestions on an assessment or one item, each with its confidence,
rationale, model and prompt version; `assessments_accept_evidence_suggestion`
and `assessments_dismiss_evidence_suggestion` (`:mcp_client`, both
`EvidencePolicy#add_link?`) decide one, exactly as the hub's buttons do.
Asking for a fresh set is the hub's "Suggest again" only: an agent that
wants a placement can read the item and add a link itself, and a tool that
spends a model call on request is a cost nobody asked to expose
([assessments/evidence.md → Suggested placement and valence](assessments/evidence.md)).

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
- **Refresh preserves the binding.** Access tokens live 8 hours and are
  renewed by a refresh token (`use_refresh_token`) so a long MCP session
  never forces a browser round trip — Doorkeeper's `RefreshTokenRequest`
  copies the `tenant_id` custom attribute from the prior token onto the
  renewed one, so the renewed token stays bound to the same tenant.
  Switching tenants still requires a fresh `/oauth/authorize` (the picker
  is only on the consent screen). This replaced the original 1-hour /
  no-refresh surface, whose hourly expiry made clients re-run the full
  browser flow — and Dynamic Client Registration — several times a
  session (alpha-tester report, June 2026).

### 7. Discovery + DCR for self-onboarding

A fresh CLI install gets a working OAuth flow from just `url:
http://localhost:6600/mcp` — no manual app registration. The chain:

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

### 13. A `Hash`/`Array` param needs a published shape AND defensive content validation

`parameter :external_reference, Hash` advertised a bare `{ type: "object" }`
(see Lesson 4) — no `properties`, so a client had nothing to copy and guessed
keys. The operation then built a typed value object from the raw payload to
validate it (`ExternalReference.new(params[:external_reference])`), and
StoreModel/ActiveModel **raised `ActiveModel::UnknownAttributeError` on any
unrecognised key** (a stray `title:`). That exception isn't a
`ParameterError`, so it fell through the request handler's final
`rescue StandardError` and reached the client as an opaque **-32603 internal
error** — telling them it was a *server* bug when it was a bad payload
(alpha-tester report, June 2026).

Two rules for any complex param:

- **Advertise the shape.** Declare `parameter :foo, Hash, schema: <json-schema
  fragment>` so the MCP tool schema shows the accepted keys (and enums).
  `Mcp::OperationToTool` emits an explicit `schema:` verbatim; without it a
  `Hash`/`Array` is a free-form object the client must reverse-engineer. Keep
  the fragment next to the model it describes (`ExternalReference.json_schema`).
- **Validate contents without raising.** Never let a value-object constructor,
  AR, or StoreModel raise *through* an operation — those become -32603. Check
  the payload first and raise `Operations::Base::ParameterError` (→ -32602) for
  anything the client got wrong, including **unknown keys** (reject them by
  name; don't silently drop them). `ExternalReference.validation_error_for`
  centralises this so all three evidence-write ops share one path. The
  request handler maps `ParameterError → -32602`; a client mistake must always
  classify as invalid-params, never internal-error, so MCP error monitors only
  fire on genuine server bugs.

### 14. The CLI parity test must pass `--strict-mcp-config`

`--mcp-config <file>` alone does not isolate the spawned CLI: it MERGES the
test server with the developer's user-scope (`~/.claude.json`) and
project-scope (`.mcp.json`) MCP servers. In the devcontainer — where the
host's `~/.claude` is bind-mounted — a dev's own unauthenticated server entry
(e.g. a "growthOS" OAuth remote) then appears in the same session as the test
server, and the model sometimes answers "that server needs authorization"
instead of calling the test tool. Flaked exactly this way in a local
precommit run. `--strict-mcp-config` restricts the session to the servers in
`--mcp-config`, making the test hermetic regardless of the developer's own
MCP configuration.

### 15. A rule the schema can't express is a rule the client can't obey

`required:` is per-parameter, so `input_schema` can only ever emit a flat
"all of these" list. Fourteen operations enforced something richer in
`perform` — and the advertised schema therefore told clients a call was valid
that the operation then rejected. The gap is invisible until an MCP client
trusts the schema.

Five declarations close the common shapes; each enforces at the parameter
boundary AND emits the matching JSON Schema, which is the point — a constraint
that lives in only one of those two places is the bug:

- **`requires_any_of :a, :b`** — at least one of a group was supplied → `anyOf`
  (several groups nest under `allOf`; flattening them into one `anyOf` would
  only ask that any single group hold). **"Supplied" means the key arrived,
  not that its value is meaty**, because that is exactly what `required` asks
  inside an `anyOf` branch. It is also what partial updates need: `""` is a
  meaningful clear, and `false` / `0` are real values.
- **`allow_blank: false`** — a supplied `""` is a mistake, not a clear →
  `minLength: 1`. Distinct from `required:`: omitting the key is still fine.
  Reach for it on names and ids; never on a description, which callers
  legitimately clear. Adopting `requires_any_of` without it silently turns
  "you must supply a name" into a no-op success.
- **`requires_when :dependent, if: :trigger, equals: "x"`** (or `in: [...]`) —
  required only when another parameter carries a given value → `if`/`then`
  (`const` for one match — `equals:` or a one-value `in:` — and `enum` for
  several). Unlike `requires_any_of`, this
  demands the dependent be **supplied AND non-blank**, because a
  conditionally-required field is conditionally *mandatory* — `""` there is the
  mistake being caught, not a clear. So the `then` branch carries `required`
  **plus** the type's non-blank keywords, and the runtime says the same. The
  `if` branch must also `required` the trigger, or an instance omitting it
  matches vacuously and gets held to `then`. Load-time guards catch a
  match value outside the trigger's own `allowed:` set — a typo'd enum would
  otherwise declare a rule that can never fire. Five operations shared two such
  rules by copy-paste before this existed.
  **`must_be:` additionally pins the dependent's VALUE** (`requires_when
  :scope_type, if: :role, equals: "role_lead", must_be: "role"`) → `const` in
  place of the non-blank keywords, being strictly stronger than either. That is
  the discriminated pair — one parameter dictating another's exact value, not
  merely its presence — and pinning it *inside* the declaration is what keeps
  schema and check from drifting.
- **`forbids_when :dependent, if: :trigger, in: [...]`** — the mirror: the
  dependent must NOT be supplied while the trigger matches → `if`/`then` with
  `not: { required: [dependent] }`. Here "supplied" is **the key arriving with
  any non-nil value**, because `not: { required: }` objects to the property
  *existing*; so `""` is a violation too, and a web form whose control stays in
  the DOM must drop the value before dispatching rather than submit an empty
  one (the archive and publish-review forms disable their hidden survivor
  select for exactly this). A present-but-null key is the one case where schema
  and runtime could differ — JSON Schema counts it as present — but the
  property's own declared type rejects null first, so the two never actually
  disagree.
- **`dependent_required :a, requires: :b`** — supplying `a` obliges `b`, with no
  trigger VALUE involved → `dependentRequired: { "a": ["b"] }` (several
  declarations merge into that one keyword rather than each taking a branch).
  This closes the hole the two value-armed rules leave open: both fire on the
  trigger's value, so **neither fires when the trigger is absent** — and an
  operation that then ignores the orphaned dependent drops it silently, exactly
  the bug they exist to stop. `archive_capability` shipped with that hole (a
  `to_stable_id` with no `mapping_type` was discarded) while advertising the
  combination as valid. Pointless on a `required:` parameter, so that is
  rejected at load time rather than emitting a rule that can never fire.

A subschema must not introduce a **new** property name:
`additionalProperties: false` is evaluated against the top-level `properties`
alone and never sees into subschemas. So an `anyOf` branch carries only
`required` — while an `if`/`then` legitimately constrains a name the top level
already declares.

Three rules of thumb when adopting these:

- **Both halves, from one list.** Wherever a trigger enum splits the callers of
  a dependent, declare the required half AND the forbidden half, deriving the
  second set by subtraction from the first (`NON_SURVIVOR_TYPES = MAPPING_TYPES
  - SURVIVOR_TYPES`, `FRAMEWORK_LEVEL_ENTITY_TYPES = ALLOWED_CREATION_KEYS.keys
  - PARENTED_ENTITY_TYPES`) so a new enum value can't fall outside both.
- **Adopting is a contract tightening.** Input that was previously accepted and
  silently dropped starts returning -32602. That is the point, but say so in the
  PR, and check the web callers: they must compact an inapplicable field to nil
  rather than send it blank or stale.
- **Cover the trigger's absence, not just its values.** `requires_when` and
  `forbids_when` both arm on a value, so a pair of them still says nothing about
  a call that omits the trigger entirely. If the dependent is meaningless
  without it, add `dependent_required` — otherwise the silent drop just moves.
- **An `:in_app` operation is validated at `tools/call` too.** The request
  handler instantiates it before minting the PendingApproval, so a tightened
  rule reaches the MCP client as -32602 rather than becoming an approval that
  fails when the user opens it. Approval-time ParameterErrors (a row whose
  arguments predate the rule) surface their own message.

Still unexpressed — a ledger, so the next round knows what it is buying:

- **Numeric bounds.** `add_level`'s `ordinal` (positive),
  `update_capability_role_binding`'s `weight` (> 0) and `individual_tolerance`
  (>= 0), and the `configure_scoring_thresholds` ranges are all checked in
  `perform` and advertised as bare `integer`/`number`. JSON Schema says this
  natively (`minimum` / `exclusiveMinimum`), so this wants a `min:`/`max:`
  clause on `parameter` — the cheapest remaining item.
- **String formats.** `reporting_evidence_coverage`'s `month` advertises a
  `YYYY-MM` `pattern` via `schema:` (documentation-only) and checks it in
  `perform` with `Reporting::CycleMonth.valid_key?` — the two are built from
  one `MONTH_PATTERN` constant so they can't drift, but a `pattern:` clause on
  `parameter` (emit `pattern`, run `match?` in `Parameter#validate!`) would
  make it one declaration and move the check to the boundary. Same shape as the
  numeric-bounds item above.
- **Per-discriminator object key sets.** `frameworks_suggest_create`'s
  `proposed_attributes` advertises the UNION of every entity type's keys with
  the per-type required/allowed sets only in prose in its `description`;
  `ALLOWED_CREATION_KEYS` and `REQUIRED_CREATION_KEYS` enforce them. Expressible
  as `if`/`then` on `entity_type` with a nested `required` + `properties`, but
  it needs a nested-object variant of the declarations rather than the top-level
  ones we have.
- **Hand-rolled blank guards that a declaration already covers.**
  `resolve_clarification` (`note`), `edit_suggestion_comment` and
  `edit_comment` (`body`), `set_behavioural_expectation` (`description`) each
  raise "can't be blank" from `perform` on a `required: true` String instead of
  declaring `allow_blank: false`. Nothing new is needed — just adoption.

Deliberately out of scope, not a gap: **relationships between two free values**
(`new_role must differ from old_role`) would need an N×N enumeration to
express, and **existence lookups** ("no such capability in this framework") are
database questions a schema can never answer. Both stay as `perform` checks by
design.

One such rule turned out not to need expressing at all. `change_collaborator_role`
enforced "old and new role must share a scope shape" in `perform` — but every
scoped lead role has its OWN entity type, so two different scoped roles never
share one, and the shape is fixed across a change. Same-shape plus
roles-must-differ therefore left **only** the framework-wide pairs: the rule was
an enum in disguise. Restricting both parameters to `FRAMEWORK_WIDE_ROLES` says
it in the schema, deletes the check, and moves the remove + add guidance into
the tool description where a client reads it before calling. Worth asking of any
surviving `perform` check: is it really a relationship, or a narrower enum you
haven't noticed?

### 16. A payload lists things in the order the page shows them

The serializer sorted each category's capabilities by name, a choice made
before capabilities could be reordered. Once a category was reordered the web
and the MCP disagreed, and an agent asked to "follow GrowthOS's order" had no
way to find it ([#492](https://github.com/mr-yum/growth-os/issues/492)). Order
is part of the content: a reader compares the two side by side. Keep the read
model's own order (`CapabilityCategory#capabilities` is `[ordinal, created_at,
id]`, categories the same) rather than re-sorting. Role families don't match
yet: the payload sorts them by name, while the role tree groups them by
department first.
`test/operations/assessments/get_test.rb` pins the capability order against
the order `Assessments::MatrixDataBuilder` renders.

### Text fields that render as Markdown

A parameter whose text renders through `Prose` (evidence content, comment
bodies, suggestion rationale, resolution notes — see
[phlex-views.md](phlex-views.md)) is declared with `prose_fields :content`.
The tool description then ends with a sentence naming the field, so an agent
writes links rather than footnotes. Name the field: `frameworks_suggest_edit`
renders its `rationale` but not its `value`, which is framework text
and stays plain, so a tool-wide "text is Markdown" would mislead.
`test/operations/registry_test.rb` fails if a declared field is not a
parameter.

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
| `app/operations/operations/base.rb` | DSL (`parameter`, `requires_any_of`, `requires_when` incl. `must_be:`, `forbids_when`, `dependent_required`, `allow_blank:`) + `#call` pipeline + `authorize` helper |
| `app/operations/operations/frameworks/collaborator_scope_rules.rb` | `declare_collaborator_scope_rules` — the role/scope pairing as declarations, shared by add + change |
| `app/operations/operations/registry.rb` | Self-registration + lazy eager-load |
| `app/operations/operations/<domain>/<noun>.rb` | Concrete Operations (one per MCP tool) |
| `app/operations/operations/reporting/evidence_coverage.rb` | Cycle feedback/evidence coverage shared by web and MCP |
| `app/operations/operations/assessments/{accept,dismiss}_evidence_suggestion.rb` / `evidence_suggestions_list.rb` | Decide and list placement suggestions — web (the hub) and MCP; `evidence_suggestion.rb` holds their shared lookup and payload |
| `app/operations/operations/assessments/feedback_recipients.rb` | The recipient directory behind "who can I give feedback to?" — over `Assessments::FeedbackRecipients`, shared with the web |
| `app/operations/operations/reporting/feedback_export.rb` | Row-level feedback export (`reporting_feedback_export`) — tenant admins only, refused while impersonating although it is a read; the web encodes the same rows as CSV |
| `app/operations/operations/assessments/read_lens.rb` / `rating_cell.rb` | Role-lens resolution for the assessment read tools and the rating tools' cell check and per-cell freeze (ADR-22) |
| `app/operations/operations/assessments/alignment_lens.rb` | The role an alignment milestone acts on, and the per-role policy check Pundit's `authorize` can't pass (ADR-22) |
| **MCP protocol plumbing** | |
| `app/services/mcp/operation_to_tool.rb` | Operation class → MCP tool descriptor |
| `app/services/mcp/request_handler.rb` | JSON-RPC dispatch (initialize, tools/*, resources/*); validates an `:in_app` operation's parameters before deferring it to approval |
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
| `test/operations/base_test.rb` | Operations DSL — parameters, `requires_any_of`, `requires_when` (+ `must_be:`), `forbids_when`, `dependent_required`, `allow_blank`, `schema:` normalisation |
| `test/mcp/operation_to_tool_test.rb` | Schema conversion rules, incl. `anyOf`/`allOf`, `if`/`then`(/`not`), `dependentRequired`, `const`, `minLength`, and string-vs-symbol `schema:` fragments |
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
