# Suggest-Create Path for Illustrations

## Context

[`Frameworks::IllustrationsController#create`](../app/controllers/frameworks/illustrations_controller.rb#L10-L62) calls `add_role_illustration` directly with no review path. Under the current classification (ADR-16), illustrations are shape-preserving and live, so this inline create works — anyone with edit rights can add an illustration immediately.

For frameworks with scoped collaborators (`role_lead`, `role_family_lead`), there should optionally be a review step: "I propose adding this illustration for the Engineering role — a role lead should confirm before it lands." This is a per-framework or per-scope policy decision.

The auto-approval pattern for direct edits by approvers (documented in [ADR-13](../docs/architecture/adrs.md#adr-13-authorization-enforced-in-the-command-handler-not-in-controllers)) suggests the solution: users with approval rights for the target illustration's role_id can create directly; users without would create a pending suggestion.

## What needs to change

### Aggregate / command handler

The existing `can_approve?(person_id, target_entity_type: "role_illustration")` at [aggregate.rb:533-552](../app/contexts/frameworks/aggregate.rb#L533-L552) already resolves whether a person has tier-1 approval rights. Extend the controller to branch:

```ruby
# IllustrationsController#create
if framework_aggregate.can_approve?(current_person.id, target_entity_type: "role_illustration")
  # Direct create — current behaviour
  handler.add_role_illustration(...)
else
  # Suggest create — requires approval
  handler.suggest_create_illustration(...)
end
```

`suggest_create_illustration` is a thin wrapper around the generic `suggest_create` from [`todos/06-suggest-create-delete-paths.md`](06-suggest-create-delete-paths.md), specialized for tier-1.

### Configuration

A framework-level setting in `FrameworkState::Framework` (or a nested store_model) to enable/disable direct create vs. suggest-always. Default: direct create for framework-wide edit roles; suggest for scope-less collaborators.

### UI

The inline "Add illustration" affordance in the framework explorer should detect approval authority and either submit the create directly (current behaviour) or submit a suggestion that shows a "Pending review" badge until approved.

### Tests

- Controller test: user with role_lead for the target role → direct create
- Controller test: user without approval rights → suggestion created, illustration not visible until approved
- System test: end-to-end flow from propose → approve → illustration visible

## Dependencies

- [`todos/06-suggest-create-delete-paths.md`](06-suggest-create-delete-paths.md) — the underlying suggest_create command must exist
- [`todos/03-suggestion-review-ui.md`](03-suggestion-review-ui.md) — the approver needs a way to see and approve pending creates

## Verification

```bash
bin/rails test test/controllers/frameworks/illustrations_controller_test.rb
bin/rails test test/system/frameworks_illustrations_system_test.rb
bin/rails development:precommit
```

## Out of scope

- Framework-level policy configuration UI (enable/disable direct create) — can be deferred behind a single default.
