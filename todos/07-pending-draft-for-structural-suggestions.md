# Pending-Draft Queue for Shape-Changing Suggestions

## Context

Under ADR-16, shape-changing events are draft-gated: they require an explicit `start_draft` call. Under the plan for [`todos/06-suggest-create-delete-paths.md`](06-suggest-create-delete-paths.md), a reviewer will be able to suggest creating a new capability or archiving an existing one — actions that are shape-changing.

There is currently no mechanism for "this suggestion, when approved, should contribute to a draft". Approving a shape-changing suggestion today would raise `"No draft in progress — call start_draft first"` unless the reviewer has separately opened a draft first.

The desired behaviour: when a shape-changing suggestion is approved, the aggregate checks whether a draft is in progress. If yes, the event joins it. If no, a pending draft is auto-opened, the event lands in it, and the draft waits for an owner/editor to publish (or for other structural suggestions to accumulate). This gives the bottom-up collaborative-improvement workflow without forcing admins to babysit every proposed change.

## What needs to change

### Aggregate behaviour

On `approve_suggestion` for a shape-changing creation/deletion:

1. If `@draft_in_progress` is true — apply the shape-changing event into the current draft
2. If `@draft_in_progress` is false — emit an implicit `DraftVersionStarted` first (started_by: the approver's person_id, target_version: `@current_version + 1`), then apply the shape-changing event

Design concerns:

- Multiple concurrent suggestions: the first approval opens the draft, subsequent ones join it. The draft owner is the first approver but subsequent approvals are allowed from any approver.
- Who publishes: only `owner` and `editor` can call `publish_version`. The pending draft stays open until they do. If structural suggestions accumulate for weeks, the draft grows.
- Abandonment: what happens if nobody publishes? A "cancel pending draft" command that reverts in-flight structural suggestions to a "pending-v(N+1)" state rather than discarding them. Or an admin-only `discard_draft` command that rejects all structural events accumulated since the implicit `DraftVersionStarted`.

### New command: `discard_draft`

```ruby
def discard_draft(framework_id, discarded_by:)
  ensure_draft_in_progress!
  # Emit DraftDiscarded; the aggregate and projection treat this as
  # "rewind to before DraftVersionStarted". The projection rebuild
  # on DraftDiscarded wipes child read models and replays the stream
  # up to (but not including) the DraftVersionStarted event.
  apply(Frameworks::Events::DraftDiscarded.new(...))
end
```

This is a larger lifecycle question: should draft events be "undoable" or should discard leave them in the stream with a marker? Events are immutable, so discard is really "a marker that the preceding DraftVersionStarted ... DraftDiscarded range should be ignored during replay." The projection rebuild logic needs to skip discarded ranges.

### Tests

- Approving a structural suggestion with no draft open → auto-opens draft
- Approving two structural suggestions from different reviewers → both land in the same draft
- Approving a structural suggestion while a draft is already open → joins existing draft
- `discard_draft` wipes in-flight structural changes and restores the published projection to the previous version

## Dependencies

- [`todos/06-suggest-create-delete-paths.md`](06-suggest-create-delete-paths.md) — the suggest-create / suggest-delete commands must exist first

## Verification

```bash
bin/rails test test/contexts/frameworks/aggregate_suggestion_test.rb
bin/rails test test/contexts/frameworks/projections/published_state_test.rb
bin/rails development:precommit
```

## Out of scope

- UI for viewing and managing the pending draft — depends on [`todos/05-draft-preview-ui.md`](05-draft-preview-ui.md)
- Cross-stream notification when a pending draft is opened — depends on notification integration
