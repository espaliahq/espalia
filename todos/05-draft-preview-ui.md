# Draft Preview UI

## Context

The draft/publish workflow is command-only today. There is no way for collaborators to see what the published framework will look like post-publish while a draft is being assembled. The [framework explorer](../app/views/frameworks/show_view.rb) reads from `FrameworkState::*` read models, which reflect the **published** state only.

Under ADR-16, shape-changing events during a draft are deferred in the published projection, so the explorer shows the pre-draft view. A collaborator who starts a draft, adds two capabilities, and wants to discuss them with peers has no way to render the in-flight state.

The architecture documented a "Draft / Editor Projection" — "replays ALL events to head, shows pending structural changes, shows inline suggested edits. What framework editors see during draft phase." This is unimplemented.

## What needs to change

### Draft projection

Option A — materialized read model tables:

Create parallel `FrameworkDraft::*` tables that mirror `FrameworkState::*` and are populated by a separate projection subscriber that does NOT skip shape-changing events during drafts. Every structural event applies to both the published projection (deferred) and the draft projection (live).

Trade-off: double storage, double write traffic, consistency questions on rebuild.

Option B — ephemeral aggregate load:

When a user visits the draft view, load the aggregate from the event store (already snapshot-supported), read its in-memory state, and render directly from that. No persistent read model.

Trade-off: slower (no index), no tenant-level querying.

Option C — virtual read model via view object:

A `FrameworkState::DraftView` that layers pending structural events on top of the published state in memory, per-request. Combines the published read model (for unchanged entities) with pending events (for new/archived/modified ones).

Trade-off: complex; easy to get wrong around derived associations.

**Recommendation: Option A** — materialised draft tables. The write overhead is small (drafts are bounded), query ergonomics match the explorer, and rebuild semantics are identical to the published projection.

### Controllers

- `GET /frameworks/:framework_id/draft` — draft explorer view, mirrors the published explorer
- `POST /frameworks/:framework_id/draft/publish` — calls `publish_version` via command handler
- `POST /frameworks/:framework_id/draft/discard` — calls `discard_draft` (see [`todos/07-pending-draft-for-structural-suggestions.md`](07-pending-draft-for-structural-suggestions.md))

### Views

Reuse as much of the framework explorer component hierarchy as possible (matrix, role tree, cell components). Override the data source from `FrameworkState` to `FrameworkDraft` in the Phlex components or via a layer of abstraction.

### Visual affordances

- Pending additions highlighted in green (new row, new cell)
- Pending archives highlighted in red (struck-through)
- Pending rewordings (editorial) shown with a diff indicator
- Banner at the top: "Viewing draft v(N+1) — [X] pending changes"
- Publish button (owner/editor only) with disabled state if `@archives_needing_mapping.any?`

### Stimulus controllers

Likely reuse existing `framework-explorer`, `tree`, `matrix` controllers unchanged. Add a new `draft-actions` controller for publish / discard / pending-changes summary.

### Tests

- Projection tests for the draft subscriber
- Controller tests for the draft routes
- System tests for the full draft view at desktop and mobile breakpoints
- Responsive behavior tests

## Dependencies

- [`todos/04-migration-mapping-ui.md`](04-migration-mapping-ui.md) — the publish button needs to link to the mapping UI if archives are pending
- [`todos/07-pending-draft-for-structural-suggestions.md`](07-pending-draft-for-structural-suggestions.md) — `discard_draft` command

## Verification

```bash
bin/rails test test/contexts/frameworks/projections/draft_state_test.rb
bin/rails test test/controllers/frameworks/draft_controller_test.rb
bin/rails test test/system/framework_draft_system_test.rb
SCREENSHOTS=1 bin/rails test test/system/framework_draft_system_test.rb  # visual verification
bin/rails development:precommit
```

## Out of scope

- Draft collaboration features (comments, pre-approvals on pending changes) — separate follow-up
- Side-by-side diff view of published vs draft — nice-to-have, not in V1
