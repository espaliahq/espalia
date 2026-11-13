# AGENTS.md

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
| `app/components/` | [phlex-views.md](docs/guidelines/phlex-views.md), [tailwindcss.md](docs/guidelines/tailwindcss.md), [theming.md](docs/guidelines/theming.md) |
| `app/assets/` | [tailwindcss.md](docs/guidelines/tailwindcss.md), [theming.md](docs/guidelines/theming.md) |
| `app/javascript/` | [javascript-stimulus.md](docs/guidelines/javascript-stimulus.md) |
| `app/services/` | [service-objects.md](docs/guidelines/service-objects.md) |
| `app/policies/` | [authorization.md](docs/guidelines/authorization.md) |
| `app/integrations/` | [hris-integration.md](docs/guidelines/hris-integration.md), [slack-integration.md](docs/guidelines/slack-integration.md), [feedback-exchange.md](docs/guidelines/feedback-exchange.md) |
| `app/contexts/` | [event-sourcing.md](docs/guidelines/event-sourcing.md) |
| `app/read_models/` | [event-sourcing.md](docs/guidelines/event-sourcing.md), [rails-models.md](docs/guidelines/rails-models.md) |
| `app/operations/` | [mcp-server.md](docs/guidelines/mcp-server.md) |
| `app/services/mcp/`, `app/controllers/mcp/`, `app/controllers/oauth/`, `app/models/mcp/`, `app/jobs/mcp/`, `app/views/mcp/`, `app/views/oauth/` | [mcp-server.md](docs/guidelines/mcp-server.md) |
| `test/` | [testing.md](docs/guidelines/testing.md) |
| `test/components/previews/` | [theming.md](docs/guidelines/theming.md) (its Lookbook section) |
| `lib/` | [lib/AGENTS.md](lib/AGENTS.md) (production eager-loading; held in the file itself) |
| `.github/` | [.github/AGENTS.md](.github/AGENTS.md) (CI workflows; held in the file itself) |

Each directory above has an `AGENTS.md` (with a peer `CLAUDE.md` stub that imports it, so Claude Code and other agents read the same instructions). Most import the relevant guideline; `lib/` and `.github/` hold their few rules in the file itself. Root `AGENTS.md` covers the cross-cutting material — architecture, commands, style, workflow, and PR practices.

## Text writing rules (when responding, writing user facing copy, comments or docs)

When responding in the chat, writing comments, docs or user facing copy, please write in alignment with the principles of Zinsser's book "On Writing Well", see following.

- Cut every word that isn't doing work. If a sentence reads the same without a word, delete it. Watch for "really," "very," "quite," "rather," "somewhat," "a bit," "in order to," "the fact that," "at this point in time."
- Prefer short words to long ones. "Use" beats "utilise." "Help" beats "facilitate." "Now" beats "at the present time." Reach for the long word only when no short one carries the meaning.
- Prefer short sentences. Break long sentences in two. If a sentence runs past about 25 words, look for the seam.
  Use active verbs. "The team shipped the feature" — not "the feature was shipped by the team." Passive voice is fine when the actor genuinely doesn't matter; otherwise, name who did what.
- Use concrete words and specific examples. "Three engineers" beats "several team members." A real example beats an abstract claim. Avoid vague nouns like "things," "stuff," "aspects," "factors."
- Cut hedges. Drop "I think," "perhaps," "it seems," "somewhat," "maybe" unless the uncertainty is the point. State the claim.
- Cut throat-clearing. No "It is interesting to note that," "It should be mentioned that," "In this section we will discuss." Start with the thing itself.
- Avoid jargon, clichés, and corporate-speak. No "leverage," "synergy," "circle back," "at the end of the day," "deep dive." Say what you mean in plain words.
- One thought per sentence, one idea per paragraph. If a paragraph covers two ideas, split it.
- Choose a tone and hold it. Don't drift between casual and formal in the same piece. Don't lurch into a different register for one clever line.
- Trust the reader. Don't explain the joke. Don't restate what you just said. Don't pre-summarise what's coming. Get to the point and move on.
- Read it aloud. If it doesn't sound like something a person would say, rewrite it.
- Rewrite. Then rewrite again. First drafts are scaffolding. The real writing happens in the cut.
- **Link every GitHub issue and PR you mention.** In chat, docs and anything else read
  outside GitHub, `#534` on its own makes the reader go and look it up; write
  [#534](https://github.com/mr-yum/growth-os/issues/534) or
  [PR #523](https://github.com/mr-yum/growth-os/pull/523) instead. Only GitHub's own
  UI (commit messages, issue and PR bodies) turns a bare number into a link, so a bare number
  is fine there and nowhere else. (Asked for 2026-09-15.)

## Overall code writing rules

- Good code communicates intent, doesn't require comments to describe it. Reach for a better name or a smaller function before reaching for an explanation.
- **The default is no comment.** A comment has to earn its place by carrying what the code cannot: a non-obvious _why_, a constraint from outside the file, or a trap that reads like a mistake. If it restates the code, names the pattern, or narrates the line below it, delete it.
- **Assume one line is enough.** A comment block is for the rare decision that genuinely needs a paragraph — not a docblock on every function, component, hook and test. A file where most declarations carry a block comment is over-commented, however good each one looks alone.
- Apply the test before writing: _would a reviewer delete this as obvious?_ If yes, don't write it. Write it when the alternative is someone "fixing" the code and breaking it, or when the reason lives somewhere they cannot see — an API contract, a library bug, a spec.
- This applies to agents especially. Explaining your reasoning is for the pull request and the chat, not the source file.

### Planning work

Before designing or planning any feature, **read the relevant guideline files** for the layers involved — do not rely on defaults. The per-directory `AGENTS.md` files load a guide only once you open a file in that directory, which is usually after the plan is made, so open these yourself with `Read`:

| When you are about to… | Read first |
|---|---|
| Plan or change a controller or route | [rails-controllers.md](docs/guidelines/rails-controllers.md) |
| Plan or change a model, migration or JSONB column | [rails-models.md](docs/guidelines/rails-models.md) |
| Plan or change a view, component or any UI | [phlex-views.md](docs/guidelines/phlex-views.md), [tailwindcss.md](docs/guidelines/tailwindcss.md), [theming.md](docs/guidelines/theming.md) |
| Colour anything, or change a role, token, preset, the Theme page or a Lookbook preview | [theming.md](docs/guidelines/theming.md) |
| Write or change a Stimulus controller | [javascript-stimulus.md](docs/guidelines/javascript-stimulus.md) |
| Reach for a service object | [service-objects.md](docs/guidelines/service-objects.md) |
| Add or change a permission, policy or `authorize` call | [authorization.md](docs/guidelines/authorization.md) |
| Write or fix a test | [testing.md](docs/guidelines/testing.md) |
| Set up or debug the environment: a cloud session, a second worktree, the macOS host, `gh` auth, or timing something in development | [dev-environment.md](docs/guidelines/dev-environment.md) |
| Verify a front-end change in the browser (mandatory for every one) | [chrome-mcp.md](docs/guidelines/chrome-mcp.md) |
| Change the favicon, app icon or web manifest | [app-icons.md](docs/guidelines/app-icons.md) |
| Change the framework explorer (`/frameworks/:id`, `/edit`) | [framework-explorer.md](docs/guidelines/framework-explorer.md), then the companion its *Where everything lives* map names for your change |
| Change an assessment screen | [assessments.md](docs/guidelines/assessments.md), then the companion its *Where everything lives* map names for your change |
| Write a query that reads ratings | [assessments/role-lens.md → Role-scoped reads](docs/guidelines/assessments/role-lens.md) |
| Change HRIS sync or the role/level mapping | [hris-integration.md](docs/guidelines/hris-integration.md), [integrations.md](docs/architecture/integrations.md) |
| Change Slack notifications, the feedback modal or an inbound Slack endpoint | [slack-integration.md](docs/guidelines/slack-integration.md) |
| Change the feedback exchange with a peer system: its settings, secrets, signing, client or signed endpoints | [feedback-exchange.md](docs/guidelines/feedback-exchange.md), [integrations.md](docs/architecture/integrations.md) |
| Add or change an event, aggregate, projection or read model | [event-sourcing.md](docs/guidelines/event-sourcing.md) |
| Bump a projection's `CODE_VERSION`, or rebuild one | [projection-rebuild.md](docs/runbooks/projection-rebuild.md) |
| Add or change an Operation, MCP tool, OAuth or DCR flow | [mcp-server.md](docs/guidelines/mcp-server.md) |
| Review a Dependabot PR, or change the `Gemfile` or a workflow | [dependencies.md](docs/guidelines/dependencies.md), [.github/AGENTS.md](.github/AGENTS.md) |
| Add Ruby under `lib/` (a cop, a rake helper, a projection tool) | [lib/AGENTS.md](lib/AGENTS.md) |
| Open or update a PR, or deliver a GitHub issue end to end | [issue-delivery.md](docs/guidelines/issue-delivery.md) |

Most features touch controllers + models + views + tests + authorization — read all five.

**Link to a guide here, never `@`-import it.** Claude Code loads an `@path` the moment the file that names it loads, so an import in this file loads its target into every session. `test/integration/agent_guidance_test.rb` fails on one.

Any new user-facing read or write surface must consider MCP coverage during planning. Default to building through `Operations::*` so the web and the MCP server share one implementation (see [mcp-server.md](docs/guidelines/mcp-server.md)); explicitly justify in the PR if MCP exposure is being skipped or deferred.

## Architecture

Four domain aggregates — two event-sourced via RES, two standard ActiveRecord:

**Event-sourced (RailsEventStore + AggregateRoot):**

- **Framework** — The career path blueprint. One RES stream per framework (`tenant-{id}/Framework-{id}`). Contains roles, capabilities, expectations, illustrations, versioning, and collaborative editing via inline suggested edits. Produces two projections: a published view (what everyone sees) and a draft/editor view (includes pending structural changes and inline suggestions).

- **Person Development** — One RES stream per person per framework (`tenant-{id}/PersonDev-{person_id}-{framework_id}`). The unified development journey — evidence, self-ratings, manager ratings, alignment conversations, growth plans, focus areas, check-ins, the recorded reporting manager, and manager-rating delegations in one stream. An "assessment" is a projection. An "alignment agreement" is a formalising event. The reporting manager is recorded as a first-class fact (authoritative for manager-rating authority); a manager can delegate manager *rating* (not alignment) for a seconded report.

- **Assessment Cycles** — One RES stream per cycle (`tenant-{id}/AssessmentCycle-{cycle_id}`). Orchestrates cohort assessment: cycle defined / closed, plus per-person enrollment events that the explicit `PersonEnrollmentSync` handler translates into PD-side events on each participant's PersonDevelopment stream: `JoinedAssessmentCycle` on enroll, `LeftAssessmentCycle` on unenroll (person-scoped removal), and `AssessmentCycleConcluded` on cycle close (the participation stands as part of the cycle's historical cohort — enrollment status `concluded`, never `withdrawn`).

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

**Capability scoping via bindings:** `CapabilityRoleBinding` ties a capability to a role with `weight` and an optional `individual_tolerance` (projected as `deficit_threshold`; `0` marks the capability **Required** — any gap blocks and nothing above the level counts until it is consistent). No category-level scope — bindings are the source of truth.

**stable_id:** UUID linking the "same" concept across framework versions. Enables trend analysis and evidence continuity across framework evolution.

**Framework versioning:** Single event stream. Draft phase bracketed by `DraftVersionStarted` / `FrameworkVersionPublished` events. `create` bootstraps a v1 draft automatically; subsequent drafts are opened explicitly via `start_draft` or **implicitly when a shape-changing suggestion is approved with no draft in progress** (the aggregate auto-opens a pending draft with `auto_opened: true`; subsequent approvals join it; owner/editor publishes). Published projection skips **shape-changing** events during a draft — events that alter the `(capability_stable_id, level_ordinal)` rating grid (see ADR-16). **Shape-preserving** changes — renames, rephrasings, illustrations, binding weight tweaks, suggestion approvals — apply immediately regardless of draft state. The aggregate enforces draft-presence for shape-changing direct commands via `ensure_draft_in_progress!`. `publish_version` rejects if any archived capability lacks a migration mapping (ADR-17).

**Suggested edits:** Atomic, inline suggestions (Google Docs style). Three review tiers: illustrations (light), capability descriptions (moderate), canonical expectations (high). Applied immediately on approval.

**Assessment migration:** On new version publish, person development streams receive `FrameworkVersionMigrated` (ratings, evidence, comments follow the migration mappings to the survivor capability), and open assessment cycles receive `FrameworkVersionRolled` (the cycle's `latest_framework_version` advances so views render the full version range, e.g. `v1–v2`). Both are dispatched by sync handlers subscribed to `FrameworkVersionPublished`. Ratings/evidence/comments on `archived`/`split` capabilities are flagged via `migration_status` for later relink/dismiss (UI deferred).

## Project Structure

```text
app/
├── contexts/        # Event-sourced bounded contexts (RES): frameworks, person_development,
│                    #   assessment_cycles — events, commands, aggregate, command handler, projections
├── read_models/     # ActiveRecord models the projections write (framework_state/, assessments, evidence…)
├── models/          # State-based ActiveRecord (Tenant, Person, User, TenantUser) + concerns
├── operations/      # Operations::* — the one write/read surface shared by web and MCP
├── queries/         # Read-side query objects (assessments, frameworks, reporting…)
├── controllers/     # Skinny controllers; every action calls `authorize`
├── policies/        # Pundit policies
├── views/           # Phlex page views
├── components/      # Phlex components: kit/ (generic primitives), shared/ (one-job
│                    #   compositions of Kit), shell/ (layout chrome)
├── dashboard/       # Home-page cards (Phlex)
├── javascript/      # Stimulus controllers (import maps)
├── integrations/    # HRIS (HiBob) and Slack adapters
├── jobs/            # Solid Queue jobs
├── notifiers/       # Noticed notification types
└── services/        # Rare cross-model orchestration, plus services/mcp/ protocol plumbing

test/                # Minitest: models, controllers, policies, components, system (Capybara), …
docs/guidelines/     # The layer guides the Planning work table points at
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
| [team-planning/](docs/team-planning/README.md) | Working on the Org Graph or Team Planning. Proposals with mockups and a plan; nothing is built yet |

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

Production is deployed to Render from `render.yaml`.

## V1 Integrations

- **HRIS sync** (HiBob, BambooHR) — pluggable adapter pattern, creates/updates Person records
- **Notifications** (Slack, Teams, email) — noticed, RES async handlers via Solid Queue, outbox pattern
- **SSO/SAML** — Devise + OmniAuth, tenant-level SSO config

## Development Commands

```bash
bin/setup                    # Install dependencies and setup database
bin/dev                      # Start development server (Overmind/Foreman) on port 6600
bin/rails server             # Standard Rails server only (PORT=6600 in the devcontainer;
                             # pass -p 6600 outside it — Rails' own default is still 3000)

bin/rails db:prepare         # Setup database (creates, migrates, seeds)
bin/rails db:migrate         # Run migrations
bin/rails db:seed            # Seed database

bin/rails test               # Run test suite (Minitest) - DO NOT pipe output
bin/rails test:system        # Run system tests (Capybara + Selenium)

# The above test tasks run as part of precommit so if you are done just run precommit, not individual test tasks

SCREENSHOTS=1 bin/rails test test/system/foo.rb  # Capture screenshots per action -> saves to tmp/screenshots/{TestClass}/{test_name}/{001_action.png}
                                                # (a namespaced class dash-joins: AssessmentCycles::Foo -> AssessmentCycles-Foo)
                                                # -> use /screenshot-test skill to run + visually examine results

# Visual verification in a real browser via the chrome-devtools MCP — the MANDATORY
# visual pass for every front-end change (additional to system tests, never a
# substitute), plus exploration and UI bug repro. Navigate to http://rails-app:6600
# (NOT localhost — the browser is a separate container). Connection relies on the
# socat forwarder started by .devcontainer/start-chrome-cdp-proxy.sh. Full setup,
# the connect-failure fix, login, viewports, and gotchas: docs/guidelines/chrome-mcp.md
# See "Visual Verification (NON-NEGOTIABLE)" below.

# Validation (NON-NEGOTIABLE)
bin/rails development:precommit  # ALWAYS run before completing development work
                                 # Runs: erblint, rubocop, brakeman, bundler audit,
                                 # importmap audit, tests, and system tests
                                 # ALWAYS fix issues, even if you think they are unrelated to our changes

bin/rubocop                  # Run RuboCop linter
bin/rubocop -a               # Auto-fix RuboCop issues
```

> **CRITICAL**: Do NOT pipe test output (e.g. `bin/rails test | cat`). Run test commands directly.
>
> Without `pipefail`, a pipeline reports its LAST command's status. So
> `bin/rails development:precommit | tail` exits 0 whenever `tail` succeeds — which is always,
> even when the task itself exited 1. Piping hides the failure as well: rake prints it above
> the summary the tail shows. Redirect to a file and read that, or set `-o pipefail`.

**In a Claude Code cloud session the app is at `http://localhost:6600`** (start it with `bin/rails server -p 6600`; `bin/dev` needs Overmind, which the image lacks). How `bin/cloud-setup` provides Ruby, Postgres and Chrome, the second-worktree setup, and running on the macOS host are in [dev-environment.md](docs/guidelines/dev-environment.md).

## Visual Verification (NON-NEGOTIABLE)

System tests remain the **source of truth** and MUST represent every piece of
functionality — this is unchanged (see [docs/guidelines/testing.md](docs/guidelines/testing.md),
including responsive coverage at both viewports). **In addition**, every
front-end change must be visually verified in a real browser via the
`chrome-devtools` MCP before it is marked done.

The two are complementary and neither discharges the other:

- The **system test** proves the behaviour *keeps* working — it runs in CI and is
  where coverage lives. CI does **not** run the MCP, so a Chrome MCP pass never
  substitutes for writing/maintaining the test.
- The **Chrome MCP pass** proves the change *actually looks and behaves right*
  now — layout, contrast, console errors, Turbo/Stimulus behaviour against the
  live app. A green suite never substitutes for laying eyes on the change.

A front-end change is done only when **both** are true: a system test covers it
AND you've visually verified it. Read
[docs/guidelines/chrome-mcp.md](docs/guidelines/chrome-mcp.md) before driving the
browser (dev URL, login, viewports, screenshot paths, gotchas). The
`SCREENSHOTS=1` + `/screenshot-test` path remains available for a repeatable,
suite-level artefact.

**The `/ux-quality` skill** (UX and WCAG 2.2 AA criteria for building, spec review and adversarial assessment) resolves this repo's design system, app URL, browser driver and screenshot folder from [chrome-mcp.md → UX quality skill](docs/guidelines/chrome-mcp.md#ux-quality-skill-ux-quality).

## Core Principles

### The Rails Way

Follow standard Rails conventions - avoid unnecessary abstractions:

- **Skinny controllers**: Delegate business logic to models
- **Fat models**: Use concerns for shared behavior, callbacks for lifecycle hooks
- **Scopes**: Reusable query logic belongs in model scopes
- **Validations**: Data integrity via ActiveRecord validations and custom validators
- **Avoid service objects**: Prefer model methods and concerns. Only use service objects for truly complex cross-model orchestration
- **Background jobs**: Use SolidQueue for async work (not service wrappers)
- **Concerns and modules**: Use for shared functionality and code organisation

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
| New component | `app/components/{kit,shared,shell}/name.rb`; layers in phlex-views.md |
| Business logic | Model methods or concerns (not services) |
| Async work | Background job in `app/jobs/` |
| New test | Shoulda + FactoryBot |
| Verify a front-end change | System test (always) **+** Chrome MCP visual pass (mandatory) — see chrome-mcp.md |
| Authorization | Pundit policy in `app/policies/`, every action calls `authorize` |
| Translatable text | `jsonb :attr_translations` + `translates :attr` |
| Complex JSON | `store_model` with type-safe models |
| Simple JSON | `store_accessor` for flat key-value |
| Slugs | Always use dashes: `"my-slug"` not `"my_slug"` |
| Stimulus fetch | `@rails/request.js` (never raw `fetch`) |
| Pagination | `pagy` |
| Nil assertions | `assert_nil value` (not `assert_equal nil, value`) |
| Show text people wrote | `render Components::Kit::Prose.new(text)`; excerpts `Prose.to_plain(text)` |

## Behaviours and practices

- Commit messages: Please use conventional commits and keep them concise. Tell us what value was created in the commit, not a catalog of changes.
- **Handing one GitHub issue to an agent (or picking one up solo)? Follow [docs/guidelines/issue-delivery.md](docs/guidelines/issue-delivery.md).** It is the delivery contract around the work itself — claim the issue, branch from the stated base, commit per change, test + visual pass, README screenshots, precommit, `/code-review`, PR body, then CI and the CodeRabbit threads — and it exists so an unsupervised run lands the same way every time.
- Always update relevant documentation if functionality diverges from what is documented.
- *CRITICAL* Commit per discrete change, creating a stacked commit, in *one* PR. Stack commits, do not stack PRs. This is about ONE piece of work: never split a single issue's change across several PRs. It does not forbid one issue's PR from being *based on* another issue's still-unmerged branch when the second genuinely builds on the first — that is one PR per issue, opened with `--base <that branch>` and retargeted as the stack lands (see [docs/guidelines/issue-delivery.md](docs/guidelines/issue-delivery.md)).
- *CRITICAL* **Commit each discrete change as soon as it is complete and verified — *before* starting the next separable piece of work**, even within a single task or session. Do not let two separable changes accumulate uncommitted in the working tree: splitting them apart after the fact is error-prone and sometimes infeasible once they touch the same files/lines. The moment you finish a working, tested unit and the next thing is separable, commit first, then continue (if you're on the default branch, create a feature branch before the first commit). If a request implies several separable changes, plan the commit boundaries up front and land each one before moving on, rather than batching everything into a single end-of-task commit.
- **Run the `/code-review` skill before creating a PR (NON-NEGOTIABLE).** Review the branch diff vs main once the work is complete and committed, and land each fix as its own stacked commit on the branch before opening the PR. This is a pre-PR gate, separate from (not a replacement for) the CodeRabbit review that runs in PR CI — both apply.
- **Before opening or updating a PR, read [issue-delivery.md](docs/guidelines/issue-delivery.md).** Track CI, then read every CodeRabbit finding and fix each as its own commit, re-checking after each push. CodeRabbit can skip a review or hide findings behind a green check, and PR screenshots have rules about what may be published; that guide covers both.
- **MCP coverage is non-optional.** Every new user-facing surface — a controller action, a command-handler entry point, a read query that drives UI — must explicitly consider MCP exposure. The default path is to build the operation under `app/operations/operations/<domain>/<noun>.rb` so the web controller AND the MCP server consume the same class (the tool surface is auto-derived via `Operations::Registry`). If you choose NOT to expose it to MCP, say why in the PR description (purely internal, security model not yet modelable in MCP, deferred to follow-up, etc). See [docs/guidelines/mcp-server.md](docs/guidelines/mcp-server.md).
- **claude.ai Artifacts are fine for mocks, plans and reports.** They are private until their owner shares them. Fill them with seeded or invented data only, never customer data, credentials or production records: the same rule as PR screenshots.

## Learnings

> **Add a learning here only when it matters in most sessions and no guide would be open at the moment it does.** Otherwise record it where its code lives: the guide the Planning work table names for that task, or the `AGENTS.md` of the directory it governs (`lib/`, `.github/`, `app/…`). Everything in this file loads into every session, and `test/integration/agent_guidance_test.rb` holds it to 40k characters.

- **A delegated agent shares your working tree, your database and your dev server.** Subagents (the `Agent` tool, the `chrome-driver` agent, a `/code-review` angle) run in the SAME checkout as the session that launched them — there is no copy-on-write. So while one is working, do NOT `git checkout`, `git pull`, `git stash` or rebase in the orchestrating session: the agent's next `Read` or test run sees a tree it never asked for, and a half-applied rebase can be attributed to its edits. Same for `bin/dev` on port 6600 and the dev database — one browser driver at a time, and a seed reset while another agent is mid-flow invalidates its run. If you must work on another branch concurrently, use a throwaway `git worktree add /tmp/wt-<name> <branch>` (or launch the agent with `isolation: "worktree"`) and delete it afterwards; a second worktree needs its own database and ports ([dev-environment.md](docs/guidelines/dev-environment.md#a-second-worktree)). Read-only agents are safe to overlap; writers are not.
- **The claude.ai GitHub MCP connector 404s on this private repo.** Use `gh` for issues, PRs, checks and review threads.
- **In Claude Code, `@path` loads a file immediately; a Markdown link doesn't.** The "Planning work" table once named every guide as `@docs/guidelines/…`, so every session in this repo loaded 20 files (~706k characters) at startup, and `framework-explorer.md` and `assessments.md`, each over the 150k per-file limit, were truncated, losing the end of each. Both are now a small core with a *Where everything lives* map, plus companions by concern under `docs/guidelines/<guide>/`; split any guide the same way once it nears the directory budget in `agent_guidance_test.rb`. Load a guide on a predicate instead: an `@` import in the `AGENTS.md` of the directory it governs (loaded only when a file there is read), or a "when X, read Y" link here. A path a guide merely mentions belongs in a link or backticks, never after a bare `@`.
