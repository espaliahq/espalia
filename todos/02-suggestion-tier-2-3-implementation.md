# Implement Tier 2 and Tier 3 Suggestion Paths

## Context

The suggested-edit mechanism ([app/contexts/frameworks/aggregate.rb](../app/contexts/frameworks/aggregate.rb)) is update-only and currently wired for **exactly one entity type**: `role_illustration`. The architecture describes three tiers of review (illustrations/light, capability descriptions/moderate, behavioural expectations/high) but tiers 2 and 3 are unimplemented — any `suggest_edit` for `capability`, `capability_category`, `behavioural_expectation`, `role`, `role_family`, or `level` raises `"Unknown entity type"` in [`raise_unless_entity_exists!`](../app/contexts/frameworks/aggregate.rb#L1035-L1042), and `approve_suggestion` has no branch to dispatch the corresponding content-change event in [`apply_suggested_content_change`](../app/contexts/frameworks/aggregate.rb#L1018-L1028).

This blocks the primary user workflow described in the framework lifecycle rework: reviewers cannot propose tier-2 or tier-3 rewording changes to the framework, so minor-feedback integration on a freshly published framework is capped at illustrations only.

Under the new classification (ADR-16), the underlying content-change events are all editorial and apply live — `RoleFamilyUpdated`, `RoleUpdated`, `LevelUpdated`, `CapabilityCategoryUpdated`, `BehaviouralExpectationUpdated`, `CapabilityRoleBindingUpdated`. The aggregate infrastructure to apply the change exists; only the suggestion-path plumbing is missing.

## What needs to change

### Entity validation — `raise_unless_entity_exists!`

Extend the switch at [aggregate.rb:1035-1042](../app/contexts/frameworks/aggregate.rb#L1035-L1042) to cover every editorial-targetable entity:

```ruby
def raise_unless_entity_exists!(entity_type, entity_id)
  case entity_type
  when "role_illustration"
    raise "Illustration #{entity_id} not found" unless @illustrations.key?(entity_id)
  when "behavioural_expectation"
    raise "Expectation #{entity_id} not found" unless @expectations.key?(entity_id)
  when "capability"
    raise "Capability #{entity_id} not found" unless @capabilities.key?(entity_id)
  when "capability_category"
    raise "Category #{entity_id} not found" unless @capability_categories.key?(entity_id)
  when "role"
    raise "Role #{entity_id} not found" unless @roles.key?(entity_id)
  when "role_family"
    raise "Role family #{entity_id} not found" unless @role_families.key?(entity_id)
  when "level"
    raise "Level #{entity_id} not found" unless @levels.key?(entity_id)
  else
    raise "Unknown entity type: #{entity_type}"
  end
end
```

### Approval dispatch — `apply_suggested_content_change`

Extend the switch at [aggregate.rb:1018-1028](../app/contexts/frameworks/aggregate.rb#L1018-L1028) to emit the matching editorial content-change event for each entity. For entities where the canonical editorial command takes multiple fields (e.g. `update_role_family(name:, description:)`), the suggestion's `field` value determines which attribute is updated. Draft the dispatcher to keep the mapping explicit:

```ruby
def apply_suggested_content_change(suggestion)
  entity = suggestion[:target_entity_type]
  field = suggestion[:field]
  new_value = suggestion[:suggested_value]
  entity_id = suggestion[:target_entity_id]
  rationale_tag = "Applied via approved suggestion #{suggestion[:suggestion_id]}"

  case [entity, field]
  when [ "role_illustration", "description" ]
    apply(Frameworks::Events::RoleIllustrationUpdated.new(data: {
      framework_id: @framework_id,
      illustration_id: entity_id,
      new_description: new_value,
      rationale: rationale_tag
    }))
  when [ "behavioural_expectation", "description" ]
    apply(Frameworks::Events::BehaviouralExpectationUpdated.new(data: {
      framework_id: @framework_id,
      expectation_id: entity_id,
      new_description: new_value,
      rationale: rationale_tag
    }))
  when [ "capability", "name" ], [ "capability", "description" ]
    # Requires the new `update_capability` command + CapabilityUpdated event
    # (see todos/01-add-update-capability-command.md — blocker for this)
  when [ "capability_category", "name" ], [ "capability_category", "description" ]
    apply(Frameworks::Events::CapabilityCategoryUpdated.new(data: {
      framework_id: @framework_id,
      category_id: entity_id,
      field.to_sym => new_value
    }))
  # ... and so on for role, role_family, level
  end
end
```

### Review tier resolution

`review_tier` at [aggregate.rb:1005-1012](../app/contexts/frameworks/aggregate.rb#L1005-L1012) already returns the correct tier for most entity types. Add cases as needed for snake-case variants and for `Level`, `RoleFamily`, `Role` (probably tier 2, following the "moderate wording review" heuristic).

### Dependencies

- Blocker: [`todos/01-add-update-capability-command.md`](01-add-update-capability-command.md) — the aggregate has no `update_capability` command yet, so capability-level suggestions cannot be approved without it.
- Related: [`todos/03-suggestion-review-ui.md`](03-suggestion-review-ui.md) — without a review UI, suggestions accumulate but can't be approved through the product.

### Tests

- Extend [`test/contexts/frameworks/aggregate_suggestion_test.rb`](../test/contexts/frameworks/aggregate_suggestion_test.rb) with contexts for each newly wired entity type:
  - `suggest_edit` raises for unknown entity IDs per entity type
  - `approve_suggestion` emits the correct content-change event for each entity
  - Competing-suggestion auto-reject works per field (not just per entity)
- Controller-level tests for any new routes.

## Verification

```bash
bin/rails test test/contexts/frameworks/aggregate_suggestion_test.rb
bin/rails development:precommit
```

End-to-end: propose a suggestion against a capability category description via console; approve it; verify the read-model row was updated and the EditSuggested + SuggestionApproved + CapabilityCategoryUpdated events appear in the stream.

## Out of scope

- `suggest_create` / `suggest_delete` paths — tracked separately in [`todos/06-suggest-create-delete-paths.md`](06-suggest-create-delete-paths.md).
- Per-entity UI — tracked in [`todos/03-suggestion-review-ui.md`](03-suggestion-review-ui.md).
