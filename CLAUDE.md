# CLAUDE.MD

Reusable AI coding guidelines for a modern Rails 8 application with Hotwire, Phlex, TailwindCSS v4, and PostgreSQL.

## System Overview

This is an open-source, multi-tenant platform for operationalising career growth frameworks, built with **Rails 8** and **RailsEventStore (RES)**. Organisations define career paths — role families, roles, levels, capabilities, and behavioural expectations — and use the platform to run self-assessments, manager alignment conversations, evidence collection, and growth planning.

The system embodies the philosophy that **performance is multi-dimensional and culture is the sum of consistently demonstrated behaviours**. Career paths serve as a cultural blueprint (what behaviours to reward), a performance map (what good looks like at each level), and a development roadmap (how to grow within or across roles).

## Guidance Files

This project uses a layered guidance system. Standards are loaded contextually — only when working in the relevant directory — to keep context lean.

| When working in | Auto-loaded guideline |
|---|---|
| `app/controllers/` | [rails-controllers.md](docs/guidelines/rails-controllers.md) |
| `app/controllers/frameworks/` | [framework-explorer.md](docs/guidelines/framework-explorer.md) |
| `app/controllers/assessments/` | [assessments.md](docs/guidelines/assessments.md) |
| `app/models/` | [rails-models.md](docs/guidelines/rails-models.md) |
| `app/views/` | [phlex-views.md](docs/guidelines/phlex-views.md), [tailwindcss.md](docs/guidelines/tailwindcss.md) |
| `app/views/frameworks/` | [framework-explorer.md](docs/guidelines/framework-explorer.md) |
| `app/views/assessments/` | [assessments.md](docs/guidelines/assessments.md) |
| `app/components/` | [phlex-views.md](docs/guidelines/phlex-views.md), [tailwindcss.md](docs/guidelines/tailwindcss.md) |
| `app/javascript/` | [javascript-stimulus.md](docs/guidelines/javascript-stimulus.md) |
| `app/services/` | [service-objects.md](docs/guidelines/service-objects.md) |
| `app/policies/` | [authorization.md](docs/guidelines/authorization.md) |
| `app/integrations/` | [hris-integration.md](docs/guidelines/hris-integration.md) |
| `app/contexts/` | [event-sourcing.md](docs/guidelines/event-sourcing.md) |
| `app/read_models/` | [event-sourcing.md](docs/guidelines/event-sourcing.md), [rails-models.md](docs/guidelines/rails-models.md) |
| `app/operations/` | [mcp-server.md](docs/guidelines/mcp-server.md) |
| `app/services/mcp/`, `app/controllers/mcp/`, `app/controllers/oauth/`, `app/models/mcp/`, `app/jobs/mcp/`, `app/views/mcp/`, `app/views/oauth/` | [mcp-server.md](docs/guidelines/mcp-server.md) |
| `test/` | [testing.md](docs/guidelines/testing.md) |

Each directory above has a `CLAUDE.md` that imports the relevant guideline. Root `CLAUDE.md` covers architecture and commands only.

### Planning work

Before designing or planning any feature, **read the relevant guideline files** for the layers involved — do not rely on defaults:

| Planning area | Read before starting |
|---|---|
| Controllers / routing | @docs/guidelines/rails-controllers.md |
| Models / migrations / JSONB | @docs/guidelines/rails-models.md |
| Views / components / UI | @docs/guidelines/phlex-views.md, @docs/guidelines/tailwindcss.md |
| JavaScript / Stimulus | @docs/guidelines/javascript-stimulus.md |
| Service objects | @docs/guidelines/service-objects.md |
| Authorization / permissions | @docs/guidelines/authorization.md |
| Tests | @docs/guidelines/testing.md |
| Framework Explorer UX | @docs/guidelines/framework-explorer.md |
| Assessment UX | @docs/guidelines/assessments.md |
| HRIS sync / role-level mapping | @docs/guidelines/hris-integration.md + @docs/architecture/integrations.md |
| Events / aggregates / projections / read models | @docs/guidelines/event-sourcing.md + @docs/runbooks/projection-rebuild.md |
| MCP server / Operations / OAuth / DCR | @docs/guidelines/mcp-server.md |

Most features touch controllers + models + views + tests + authorization — read all five.

Any new user-facing read or write surface must consider MCP coverage during planning. Default to building through `Operations::*` so the web and the MCP server share one implementation (see [mcp-server.md](docs/guidelines/mcp-server.md)); explicitly justify in the PR if MCP exposure is being skipped or deferred.

## Architecture

Four domain aggregates — two event-sourced via RES, two standard ActiveRecord:

**Event-sourced (RailsEventStore + AggregateRoot):**

- **Framework** — The career path blueprint. One RES stream per framework (`tenant-{id}/Framework-{id}`). Contains roles, capabilities, expectations, illustrations, versioning, and collaborative editing via inline suggested edits. Produces two projections: a published view (what everyone sees) and a draft/editor view (includes pending structural changes and inline suggestions).

- **Person Development** — One RES stream per person per framework (`tenant-{id}/PersonDev-{person_id}-{framework_id}`). The unified development journey — evidence, self-ratings, manager ratings, alignment conversations, growth plans, focus areas, and check-ins in one stream. An "assessment" is a projection. An "alignment agreement" is a formalising event.

- **Assessment Cycles** — One RES stream per cycle (`tenant-{id}/AssessmentCycle-{cycle_id}`). Orchestrates cohort assessment: cycle defined / closed, plus per-person enrollment events that the explicit `PersonEnrollmentSync` handler translates into PD-side `JoinedAssessmentCycle` / `LeftAssessmentCycle` events on each participant's PersonDevelopment stream.

**Read-model ownership invariant:** every table in `app/read_models/` has exactly one projection writer. Overlapping data across contexts is modelled as two tables joined at read time (e.g. enrollment + progress for a cycle participant, joined via `AssessmentCycleParticipation`) — never as a shared row. See [docs/guidelines/event-sourcing.md](docs/guidelines/event-sourcing.md).

**State-based (standard ActiveRecord):**

- **Tenant** — Organisation configuration, SSO, HRIS sync config, notification preferences.
- **Person** — Org chart entity (name, email, role, level, manager). Often synced from HRIS.

**Authentication entity (Devise, separate from domain):**

- **User** — Global authentication identity. Has credentials, sessions, Devise modules. NOT tenant-scoped — a single User can belong to multiple tenants via `TenantUser` join records. Has a `global_admin` flag for platform-level administration.
- **TenantUser** — Tenant-scoped join record linking a User to a Tenant. Carries the user's role within that tenant (`member` | `admin`) and an optional link to the Person domain entity.

## Multi-tenancy

Uses `acts_as_tenant` with row-level `tenant_id` isolation on all tenant-scoped ActiveRecord models (Person, TenantUser, all projection read models, FrameworkTemplate when tenant-authored). `User` is NOT tenant-scoped — it is a global identity. Tenant context is resolved per-request from `session[:current_tenant_id]` and stored on `ActsAsTenant.current_tenant`.

The RES event store tables (`event_store_events`, `event_store_events_in_streams`) are NOT managed by acts_as_tenant. Tenant isolation in the event store is achieved via **tenant-namespaced stream names**: `tenant-{tenant_id}/Framework-{framework_id}`. Stream names are always constructed via `EventStreamNaming` helper — never built by hand.

Event handlers (projections) set tenant context from event metadata before touching any ActiveRecord read models:

```ruby
ActsAsTenant.with_tenant(Tenant.find(event.metadata[:tenant_id])) do
  # update projection read models — acts_as_tenant scoping is active
end
```

## Key Domain Concepts

**Two-layer expectations:** `BehaviouralExpectation` (one per Capability × Level) is the canonical definition people are rated against. `RoleIllustration` (multiple per Capability × Role × Level) provides clarifying examples — NOT separately rated.

**Capability scoping via bindings:** `CapabilityRoleBinding` ties a capability to a role with `weight` and `requirement_type` (`must_have` | `flexible`). No category-level scope — bindings are the source of truth.

**stable_id:** UUID linking the "same" concept across framework versions. Enables trend analysis and evidence continuity across framework evolution.

**Framework versioning:** Single event stream. Draft phase bracketed by `DraftVersionStarted` / `FrameworkVersionPublished` events. `create` bootstraps a v1 draft automatically; subsequent drafts are opened explicitly via `start_draft` or **implicitly when a shape-changing suggestion is approved with no draft in progress** (the aggregate auto-opens a pending draft with `auto_opened: true`; subsequent approvals join it; owner/editor publishes). Published projection skips **shape-changing** events during a draft — events that alter the `(capability_stable_id, level_ordinal)` rating grid (see ADR-16). **Shape-preserving** changes — renames, rephrasings, illustrations, binding weight tweaks, suggestion approvals — apply immediately regardless of draft state. The aggregate enforces draft-presence for shape-changing direct commands via `ensure_draft_in_progress!`. `publish_version` rejects if any archived capability lacks a migration mapping (ADR-17).

**Suggested edits:** Atomic, inline suggestions (Google Docs style). Three review tiers: illustrations (light), capability descriptions (moderate), canonical expectations (high). Applied immediately on approval.

**Assessment migration:** On new version publish, person development streams receive `FrameworkVersionMigrated`. Ratings migrate per mapping rules. Nothing silently dropped — archived capabilities surface for relink/dismiss.

## Project Structure

```
app/
├── models/                          # State-based ActiveRecord
│   ├── tenant.rb                    # acts_as_tenant root
│   ├── person.rb                    # acts_as_tenant :tenant
│   ├── user.rb                      # Devise + acts_as_tenant :tenant
│   └── application_record.rb
│
├── contexts/                        # Domain bounded contexts (RES)
│   ├── frameworks/
│   │   ├── events/                  # RES event classes
│   │   ├── commands/                # Command objects
│   │   ├── aggregate.rb             # include AggregateRoot
│   │   ├── command_handler.rb
│   │   └── projections/             # Synchronous read model builders
│   │
│   ├── person_development/
│   │   ├── events/
│   │   ├── commands/
│   │   ├── aggregate.rb
│   │   ├── command_handler.rb
│   │   └── projections/
│   │
│   └── reporting/                   # Cross-stream read models
│
├── read_models/                     # ActiveRecord models for projections
│   ├── framework_state/             # Published framework tables
│   ├── assessment_state.rb
│   ├── growth_plan_state.rb
│   └── reporting/
│
├── integrations/                    # HRIS, notifications, SSO adapters
│
└── controllers/
    └── api/v1/                      # JSON API
```

## Design Documents

Architecture docs are split into focused files — read on demand, not all at once:

| File | Read when |
|------|-----------|
| [adrs.md](docs/architecture/adrs.md) | Making architectural decisions; understanding *why* things are built a certain way |
| [domain-models.md](docs/architecture/domain-models.md) | Working on Tenant, User, TenantUser, or Person; auth or multi-tenancy logic |
| [08-framework-lifecycle.md](docs/08-framework-lifecycle.md) | Understanding drafts, suggestions, publishing, migration — conceptual overview before diving into the aggregate |
| [framework-aggregate.md](docs/architecture/framework-aggregate.md) | Framework features — roles, capabilities, expectations, illustrations, versioning, collaborators |
| [person-development-aggregate.md](docs/architecture/person-development-aggregate.md) | Assessments, evidence, growth plans, alignment conversations, check-ins |
| [scoring-model.md](docs/architecture/scoring-model.md) | Assessment scoring, capability matrix display, performance verdicts, promotion readiness |
| [reporting.md](docs/architecture/reporting.md) | Gap analysis, trend analysis, promotion readiness dashboards, growth plan freshness |
| [integrations.md](docs/architecture/integrations.md) | HRIS sync, notification adapters, SSO/SAML |
| [event-store.md](docs/architecture/event-store.md) | Event subscriptions, new projections, snapshots, async handlers |

Other reference docs:
- `docs/01-architecture-and-design.md` — Index with product capabilities and module boundary diagram
- `docs/02-glossary.md` — Domain and technical term definitions
- `docs/03-entity-relationships.mermaid` — ERD across all aggregates
- `docs/04-event-flow.mermaid` — Domain event flow between aggregates
- `docs/05-framework-structure.mermaid` — Two-layer expectation model
- `docs/06-person-development-timeline.mermaid` — Worked example of person development events
- `docs/07-versioning-flow.mermaid` — Framework versioning in event-sourced model
- `docs/08-framework-lifecycle.md` — Human-friendly guide to drafts, suggestions, publishing, and migration

## Deployment Model

Runs standalone with Postgres + Solid Queue. Includes a SaaS control plane (tenant provisioning, billing, managed SSO routing) as part of the open-source codebase. Domain modules must never depend on SaaS control plane infrastructure.

## V1 Integrations

- **HRIS sync** (HiBob, BambooHR) — pluggable adapter pattern, creates/updates Person records
- **Notifications** (Slack, Teams, email) — noticed, RES async handlers via Solid Queue, outbox pattern
- **SSO/SAML** — Devise + OmniAuth, tenant-level SSO config

## Development Commands

```bash
bin/setup                    # Install dependencies and setup database
bin/dev                      # Start development server (Overmind/Foreman)
bin/rails server             # Standard Rails server only

bin/rails db:prepare         # Setup database (creates, migrates, seeds)
bin/rails db:migrate         # Run migrations
bin/rails db:seed            # Seed database

bin/rails test               # Run test suite (Minitest) - DO NOT pipe output
bin/rails test:system        # Run system tests (Capybara + Selenium)

# The above test tasks run as part of precommit so if you are done just run precommit, not individual test tasks

SCREENSHOTS=1 bin/rails test test/system/foo.rb  # Capture screenshots per action -> saves to tmp/screenshots/{TestClass}/{test_name}/{001_action.png} -> use /screenshot-test skill to run + visually examine results

# Validation (NON-NEGOTIABLE)
bin/rails development:precommit  # ALWAYS run before completing development work
                                 # Runs: erblint, rubocop, brakeman, bundler audit,
                                 # importmap audit, tests, and system tests
                                 # ALWAYS fix issues, even if you think they are unrelated to our changes

bin/rubocop                  # Run RuboCop linter
bin/rubocop -a               # Auto-fix RuboCop issues
```

> **CRITICAL**: Do NOT pipe test output (e.g. `bin/rails test | cat`). Run test commands directly.

## Core Principles

### The Rails Way

Follow standard Rails conventions - avoid unnecessary abstractions:

- **Skinny controllers**: Delegate business logic to models
- **Fat models**: Use concerns for shared behavior, callbacks for lifecycle hooks
- **Scopes**: Reusable query logic belongs in model scopes
- **Validations**: Data integrity via ActiveRecord validations and custom validators
- **Avoid service objects**: Prefer model methods and concerns. Only use service objects for truly complex cross-model orchestration
- **Background jobs**: Use SolidQueue for async work (not service wrappers)
- **Concerns and modules**: Use for shared functionality and code organization

### Ruby Style

- 2 spaces for indentation, snake_case for variables/methods
- Use `class Module::ClassName` instead of nested module/class definitions
- Add YARD documentation to all public methods and classes
- Use `frozen_string_literal: true` magic comment

```ruby
# Good
class Api::V1::UsersController < ApplicationController; end

# Bad - nested modules
module Api
  module V1
    class UsersController < ApplicationController; end
  end
end
```

## Key Directories

```
app/
  components/kit/          # Phlex Kit components (Button, Card, Alert, etc.)
  controllers/             # Rails controllers (skinny)
  jobs/                    # Background jobs (SolidQueue)
  models/                  # Fat models with concerns
  models/concerns/         # Shared model modules
  policies/                # Pundit authorization policies
  views/                   # Phlex page views (new) + ERB (legacy)

config/
  routes/                  # Modular route definitions

test/
  models/                  # Model tests
  controllers/             # Controller integration tests
  system/                  # System tests (Capybara)
  components/              # Component unit tests
```

## Technology Stack

- **Rails 8** with Hotwire (Turbo + Stimulus)
- **PostgreSQL** with UUID v7 primary keys, JSONB columns
- **RailsEventStore (RES) ~> 2.16+** — Event store, aggregate roots, projections, event subscriptions
- **SolidQueue** (jobs), **SolidCache** (cache), **SolidCable** (websockets)
- **Import Maps** for JavaScript (no Node.js dependency)
- **TailwindCSS v4** via tailwindcss-rails gem
- **Phlex 2.x** for views and components
- **Devise** for authentication
- **Pundit** for authorization
- **Minitest** with Shoulda + FactoryBot for testing
- **store_model** for typed JSONB columns
- **json_translate** for model translations
- **has_prefix_id** for human-readable API IDs
- **pagy** for pagination
- **@rails/request.js** for Stimulus fetch requests

## Quick Reference

| Task | Pattern |
|------|---------|
| New model | UUID v7: `create_table :x, id: :uuid` |
| API-facing ID | `has_prefix_id :prefix` |
| New view | Phlex in `app/views/resource/action_view.rb` |
| New component | Kit in `app/components/kit/component_name.rb` |
| Business logic | Model methods or concerns (not services) |
| Async work | Background job in `app/jobs/` |
| New test | Shoulda + FactoryBot |
| Authorization | Pundit policy in `app/policies/`, every action calls `authorize` |
| Translatable text | `jsonb :attr_translations` + `translates :attr` |
| Complex JSON | `store_model` with type-safe models |
| Simple JSON | `store_accessor` for flat key-value |
| Slugs | Always use dashes: `"my-slug"` not `"my_slug"` |
| Stimulus fetch | `@rails/request.js` (never raw `fetch`) |
| Pagination | `pagy` |
| Nil assertions | `assert_nil value` (not `assert_equal nil, value`) |

## Behaviours and practices

- Commit messages: Please use conventional commits and keep them concise. Tell us what value was created in the commit, not a catalog of changes.
- Always update relevant documentation if functionality diverges from what is documented.
- `/coderabbit:review --base main` - Use CodeRabbit to review the change code vs main branch before commit, if using CodeRabbit CLI use the `--agent` flag
- When creating PR, always track CI, always investigate code review and CodeRabbit suggestions and commit each fix as a separate commit in the PR. Always check for fresh code review comments after each commit. 
- **MCP coverage is non-optional.** Every new user-facing surface — a controller action, a command-handler entry point, a read query that drives UI — must explicitly consider MCP exposure. The default path is to build the operation under `app/operations/operations/<domain>/<noun>.rb` so the web controller AND the MCP server consume the same class (the tool surface is auto-derived via `Operations::Registry`). If you choose NOT to expose it to MCP, say why in the PR description (purely internal, security model not yet modelable in MCP, deferred to follow-up, etc). See [docs/guidelines/mcp-server.md](docs/guidelines/mcp-server.md).

## Learnings

> **CRITICAL**: Any important learnings, add them here.

- **Anything under `lib/` is eager-loaded in production.** `config.autoload_lib(ignore: %w[...])` in `config/application.rb` makes Zeitwerk eager-load all of `lib/` except the listed subdirs. A file there that references a constant from a `:development, :test`-only gem (e.g. a custom RuboCop cop subclassing `RuboCop::Cop::Base`) passes the test suite — where the gem IS loaded — but raises `NameError` at production boot and crashes the server (incident: PRs #106/#108). When adding non-app Ruby under `lib/`, either add its subdir to the `autoload_lib` ignore list or keep it out of `lib/`. CI guards this via the `production_boot` job (eager-loads with `BUNDLE_WITHOUT=development:test`); reproduce locally with `BUNDLE_WITHOUT=development:test RAILS_ENV=production SECRET_KEY_BASE=x bin/rails zeitwerk:check`.

