Read the following guidelines before working in this directory:

@../../../docs/guidelines/event-sourcing.md

One stream per tenant holds the five tables plans are priced from: pay bands, exchange rates, the reference currency, budget lines and rule defaults. `Projections::Tables` is their only writer, and writes `tenants.pay_bands_changed_at` too.

- **A command takes the stream lock alone.** The release before a4 took `pay_bands:<tenant>` and then the stream lock. A command here never asks for the list lock, so it never waits on it while holding the stream's, and the two releases can't deadlock in either order. `test/models/pay_band_locking_test.rb` holds both orders.
- **No catch-up.** Since a1 no release writes the tables directly, so a command trusts the stream. `events:reconcile` still runs at predeploy and records anything that differs.
- **`changed?` compares what `held_in_stream` reads back.** Both sides go through `Rows.cast`, as the table types read them. Compare raw values and `"120000.0"` differs from `120000.00`, so every run records a change.
- **`PlanningRuleDefaultCleared` comes from the reconciler only.** No tool clears a rule default today, and none is added here.
- **A row names its last editor by person only, in `updated_by_person_id`.** a4b dropped `updated_by_id`. Never deploy a4 or an earlier release: they name the column, and a4's predeploy `events:reconcile` reads it.
- **The figures stay in the stream for good, unencrypted.** They name no person, so forgetting leaves them alone. Events name their actor by person id only (`changed_by_id`).
- **The move carries today's rules exactly.** A rule about one row stays a validation on its model; the aggregate holds only the rules that span rows, with today's messages.
- **The history reads the whole stream.** A removal carries only its row's id, so `TenantPlanningInputs::History` folds every event forward to know what each change replaced. The screens on the pay band, rates and budget pages and the `tenants_planning_inputs_history` tool read it, admins only. It never shows inside a plan.
