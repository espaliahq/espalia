# Suggestion Review UI - Done

## Context

The suggestion framework in [`app/contexts/frameworks/aggregate.rb`](../app/contexts/frameworks/aggregate.rb) emits events for `EditSuggested`, `SuggestionAmended`, `SuggestionApproved`, `SuggestionRejected`, and `SuggestionWithdrawn`. Suggestions accumulate in the `FrameworkState::SuggestedEdit` read model but **there is no UI to list, review, approve, or reject them**.

[`Frameworks::IllustrationsController#update`](../app/controllers/frameworks/illustrations_controller.rb#L65-L90) emits `suggest_edit` for illustration rephrasings, but nowhere in the product can a reviewer see the pending suggestion, accept it, or reject it. The only path that triggers a content change is the "auto-approve" branch in the command handler for users with approval authority — but that bypasses the whole reviewer-in-the-loop pattern.

This is the largest user-facing gap blocking the continuous-feedback workflow described in the framework lifecycle rework. Without a review UI, tier-2 and tier-3 suggestions (once [`todos/02-suggestion-tier-2-3-implementation.md`](02-suggestion-tier-2-3-implementation.md) lands) will also accumulate with nowhere to go.

## What needs to change

### Controllers

Add `app/controllers/frameworks/suggestions_controller.rb`:

- `GET /frameworks/:framework_id/suggestions` — list pending (and optionally historical) suggestions, filtered by tier / entity type / scope
- `GET /frameworks/:framework_id/suggestions/:id` — show a single suggestion with diff, target entity, and author
- `POST /frameworks/:framework_id/suggestions/:id/approve` — dispatch `approve_suggestion` command; requires the current person to pass `framework.can_approve?(person_id, target_entity_type:)`
- `POST /frameworks/:framework_id/suggestions/:id/reject` — dispatch `reject_suggestion` command
- `POST /frameworks/:framework_id/suggestions/:id/amend` — author-only, dispatch `amend_suggestion`
- `DELETE /frameworks/:framework_id/suggestions/:id` — author-only, dispatch `withdraw_suggestion`

Authorization in each action via Pundit: `authorize suggestion, :approve?` where `FrameworkSuggestionPolicy#approve?` delegates to `framework.can_approve?`.

### Pundit policy

`app/policies/framework_suggestion_policy.rb` — wraps `framework.can_approve?` per tier. See [aggregate.rb:533-552](../app/contexts/frameworks/aggregate.rb#L533-L552) for the tier rules.

### Views

Phlex components under `app/views/frameworks/suggestions/`:

- `IndexView` — grouped list by tier (tier 3 first), filterable
- `ShowView` — side-by-side diff, approve/reject buttons, comment thread
- `PanelFrame` — embed into framework explorer's right pane (currently a placeholder per [framework-explorer.md](../docs/guidelines/framework-explorer.md#future-extension-points))
- `InlineIndicator` — small badge on framework entities indicating pending suggestion count; clickable to jump into review

### Framework explorer integration

Update the framework explorer's right pane placeholder to show suggestions in context of the currently-focused cell / row / category. Selection focus hierarchy: cell → row → category → framework. See [framework-explorer.md](../docs/guidelines/framework-explorer.md#future-extension-points).

### Tests

- Policy tests for `FrameworkSuggestionPolicy` — tier-based approval, author-only amend/withdraw
- Controller tests for all actions, including denied-access paths
- Phlex component tests
- System tests for the list → approve → content-update flow

## Dependencies

- [`todos/02-suggestion-tier-2-3-implementation.md`](02-suggestion-tier-2-3-implementation.md) — until this lands, only illustration suggestions can be approved through the UI.

## Verification

```bash
bin/rails test test/controllers/frameworks/suggestions_controller_test.rb
bin/rails test test/policies/framework_suggestion_policy_test.rb
bin/rails test test/system/framework_suggestions_system_test.rb
bin/rails development:precommit
```

Screenshot verification via [`/screenshot-test`](docs/guidelines/testing.md#visual-verification-with-screenshots) for the list, detail, and in-context panel views.

## Out of scope

- `suggest_create` / `suggest_delete` UI — depends on [`todos/06-suggest-create-delete-paths.md`](06-suggest-create-delete-paths.md).
- Notification integration (Slack/email on new suggestion) — separate follow-up.
