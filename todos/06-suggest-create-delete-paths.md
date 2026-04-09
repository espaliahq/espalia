# Suggest-Create and Suggest-Delete Paths

## Context

The suggestion mechanism in [`app/contexts/frameworks/aggregate.rb`](../app/contexts/frameworks/aggregate.rb) is **update-only**: `suggest_edit` takes a `target_entity_id` that must already exist (validated in [`raise_unless_entity_exists!`](../app/contexts/frameworks/aggregate.rb#L1035-L1042)) and proposes a new value for a specific `field`.

There is no way for a reviewer to say:

- "We should add an illustration for L4 Strategic Thinking under the Engineering role" (suggest_create)
- "This capability is obsolete and should be archived" (suggest_delete)

Today these actions require either direct command dispatch (`add_role_illustration`, `archive_capability`) or going through an admin who can open a draft and publish. The collaborative, reviewer-in-the-loop pattern breaks down for add/delete intent.

## What needs to change

### New events

Create `Frameworks::Events::EntityCreationSuggested` and `Frameworks::Events::EntityDeletionSuggested`:

```ruby
# entity_creation_suggested.rb
# data: { framework_id, suggestion_id, target_entity_type, proposed_attributes, parent_id, author_id, rationale }

# entity_deletion_suggested.rb
# data: { framework_id, suggestion_id, target_entity_type, target_entity_id, author_id, rationale }
```

### Aggregate commands

Add `suggest_create` and `suggest_delete` to the aggregate:

```ruby
def suggest_create(framework_id, suggestion_id, target_entity_type, proposed_attributes,
                   parent_id:, author_id:, rationale: nil)
  ensure_created!
  raise "Suggestion #{suggestion_id} already exists" if @pending_edits.key?(suggestion_id)
  raise_unless_parent_exists!(target_entity_type, parent_id)
  validate_proposed_attributes!(target_entity_type, proposed_attributes)

  apply(Frameworks::Events::EntityCreationSuggested.new(data: { ... }))
end

def suggest_delete(framework_id, suggestion_id, target_entity_type, target_entity_id,
                   author_id:, rationale: nil)
  ensure_created!
  raise_unless_entity_exists!(target_entity_type, target_entity_id)
  apply(Frameworks::Events::EntityDeletionSuggested.new(data: { ... }))
end
```

### Approval dispatch

Extend `apply_suggested_content_change` (or create a parallel `apply_suggested_creation` / `apply_suggested_deletion`) to dispatch the corresponding command on approval.

**Design tension — shape-changing creates/deletes:**

- Suggesting the addition of a capability or level (shape-changing) → approval should auto-open a pending draft, queue the event, and leave the draft for an admin to publish. This is the "pending draft" model — see [`todos/07-pending-draft-for-structural-suggestions.md`](07-pending-draft-for-structural-suggestions.md).
- Suggesting the addition of an illustration (shape-preserving) → approval applies immediately via `add_role_illustration`.

The creation suggestion event carries enough data to reconstruct the command. On approval, the aggregate dispatches the correct command depending on the target entity type.

### Review tier

- `suggest_create` for tier-1 entities (illustrations) → any edit-role holder can approve
- `suggest_create` for tier-2/3 entities (capabilities, expectations, etc.) → tier-appropriate reviewer
- `suggest_delete` always escalates: deleting a tier-1 entity still warrants tier-1 review, but deleting a capability is tier-3 (shape-changing, affects cycles)

### Tests

- Aggregate tests per entity type per suggest_create / suggest_delete
- Competing-suggestion auto-reject (e.g. two proposals to delete the same capability, approving one)
- End-to-end: propose illustration create → approve → verify `add_role_illustration` event + read-model row

## Dependencies

- [`todos/03-suggestion-review-ui.md`](03-suggestion-review-ui.md) — UI to surface create/delete proposals
- [`todos/07-pending-draft-for-structural-suggestions.md`](07-pending-draft-for-structural-suggestions.md) — approval of shape-changing creates
- [`todos/02-suggestion-tier-2-3-implementation.md`](02-suggestion-tier-2-3-implementation.md) — creates for non-illustration entities require the tier 2/3 plumbing

## Verification

```bash
bin/rails test test/contexts/frameworks/aggregate_suggestion_test.rb
bin/rails development:precommit
```

End-to-end: propose the creation of a new illustration via console → approve → verify event stream contains EntityCreationSuggested + SuggestionApproved + RoleIllustrationAdded.

## Out of scope

- Bulk propose-delete (e.g. archive a whole category and all its capabilities) — needs separate design.
