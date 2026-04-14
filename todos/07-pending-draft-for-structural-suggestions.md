# Pending-Draft Queue for Shape-Changing Suggestions - Done (auto-open); Deferred (discard_draft)

## Status

**Auto-open behaviour: DONE.** Approving a shape-changing suggestion with no draft in progress now implicitly emits `DraftVersionStarted(auto_opened: true)` before the structural event. Subsequent approvals join the same draft. Owner/editor publishes when ready.

**`discard_draft` command: DEFERRED** to a follow-up todo. Requires `DraftDiscarded` event, replay-skip range logic in both aggregate `on` handlers and `PublishedState#rebuild_framework_projection`, plus design decisions about whether discard rejects/archives/rewinds in-flight suggestions. Until implemented, un-published auto-opened drafts just accumulate structural changes.

## What was implemented

### Aggregate (`app/contexts/frameworks/aggregate.rb`)

- `SHAPE_CHANGING_CREATE_TYPES` = `capability`, `behavioural_expectation`, `level`
- `SHAPE_CHANGING_DELETE_TYPES` = `capability`
- `maybe_auto_open_draft_for(suggestion, reviewer_id)` — called inside `approve_suggestion` after `SuggestionApproved`, before the structural dispatch. If `!@draft_in_progress && shape_changing_suggestion?(suggestion)`, emits `DraftVersionStarted(target_version: @current_version + 1, started_by: reviewer_id, auto_opened: true)`.
- `shape_changing_suggestion?(suggestion)` — classifies by kind + target_entity_type.

### Projection fix (`app/contexts/frameworks/projections/published_state.rb`)

Surfaced a pre-existing latent bug: `rebuild_framework_projection` replayed suggestion events on top of existing `FrameworkState::SuggestedEdit` rows (not wiped by `destroy_framework_children`), causing `RecordNotUnique`. Fixed by adding `SUGGESTION_EVENT_CLASSES` and `suggestion_event?(event)` to `skip_during_rebuild?`. Suggestion read models persist independently across version rebuilds.

### Tests

- `test/contexts/frameworks/aggregate_suggestion_test.rb` — 9 new auto-open scenarios (capability, expectation, level auto-open; delete auto-open; two approvals joining one draft; explicit draft not doubled; shape-preserving creation/deletion/edit not opening drafts).
- `test/contexts/frameworks/projections/published_state_test.rb` — 1 new end-to-end test (suggest_create capability → approve → draft auto-opened + capability deferred → publish → capability visible after rebuild).

## What is deferred

### `discard_draft` command

See the original design below. This requires:
1. A `DraftDiscarded` event
2. Aggregate `on` handler resetting draft state
3. Replay-skip logic: the projection must identify `DraftVersionStarted … DraftDiscarded` ranges and skip all events within them during rebuild
4. Design decision: does discard reject all in-flight structural suggestions? Archive them? Rewind them back to "pending"?

Until this ships, an auto-opened draft with no publish just sits open indefinitely.

## Original context (for reference)

Under ADR-16, shape-changing events are draft-gated: they require an explicit `start_draft` call. Under [`todos/06-suggest-create-delete-paths.md`](06-suggest-create-delete-paths.md), a reviewer can suggest creating a new capability or archiving an existing one — actions that are shape-changing.

The desired behaviour (now implemented): when a shape-changing suggestion is approved, the aggregate checks whether a draft is in progress. If yes, the event joins it. If no, a pending draft is auto-opened, the event lands in it, and the draft waits for an owner/editor to publish.

## Dependencies

- [`todos/06-suggest-create-delete-paths.md`](06-suggest-create-delete-paths.md) — done

## Verification

```bash
bin/rails test test/contexts/frameworks/aggregate_suggestion_test.rb
bin/rails test test/contexts/frameworks/projections/published_state_test.rb
bin/rails development:precommit
```

## Out of scope

- UI for viewing and managing the pending draft — depends on [`todos/05-draft-preview-ui.md`](05-draft-preview-ui.md)
- Cross-stream notification when a pending draft is opened — depends on notification integration
- `discard_draft` / abandonment lifecycle — deferred follow-up
