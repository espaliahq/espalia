# Binding Weight Review Trail

## Context

ADR-16 classifies `CapabilityRoleBindingUpdated` (weight and individual_tolerance) as editorial / live: weight changes apply immediately to the published view and affect all in-flight assessment cycles' scoring outcomes. This matches `configure_scoring_thresholds` semantics, which is intentionally live per an earlier architectural decision.

The trade-off: a lead with edit rights can silently shift the scoring weight on a capability while cycles are active, and nothing in the system captures who changed what or why. Ratings in an active cycle can suddenly mean something different to the scoring output, invisibly.

This is a conscious decision for the current plan — keeping it simple and consistent with existing scoring tuning — but it's worth revisiting if product feedback surfaces concerns about silent score changes.

## What needs to change (if/when the decision reverses)

### Option A: Audit trail only

Keep weight updates live, but emit an additional audit event on every change:

- `CapabilityRoleBindingUpdated` continues to fire as today
- A dedicated "binding weight audit" read model captures `{ binding_id, old_weight, new_weight, changed_by, changed_at, reason }`
- Settings page surfaces the audit log per binding

Smallest change; gives accountability without blocking.

### Option B: Route through suggestion framework

Weight changes become tier-3 suggestions:

- `update_capability_role_binding` no longer directly dispatches the event; instead emits `EditSuggested` for `target_entity_type: "capability_role_binding"`, `field: "weight"`
- Auto-approval pattern: if the caller has tier-3 approval rights, the command chains `EditSuggested` + `SuggestionApproved` + `CapabilityRoleBindingUpdated` atomically
- Callers without rights emit a pending suggestion
- UI shows pending weight changes per binding; reviewer approves/rejects

Depends on [`todos/02-suggestion-tier-2-3-implementation.md`](02-suggestion-tier-2-3-implementation.md).

### Option C: Draft-gate binding weight changes

Make weight changes shape-changing per ADR-16 and gate behind drafts. Means every weight tweak bumps a framework version.

Probably over-rotating: a weight is a numerical parameter, not a shape change. Listed only for completeness.

**Recommendation (if this todo lands):** Option A first (cheap, unblocks accountability), then Option B if product tells us reviewer-in-the-loop is warranted.

## Verification

```bash
bin/rails test test/contexts/frameworks/aggregate_test.rb
bin/rails test test/controllers/frameworks/settings_controller_test.rb
bin/rails development:precommit
```

## Out of scope

- Retroactive recalculation of existing ratings when a weight changes — ratings are immutable events; scoring is a computed projection.
