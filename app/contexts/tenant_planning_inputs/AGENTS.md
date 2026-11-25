Read the following guidelines before working in this directory:

@../../../docs/guidelines/event-sourcing.md

One stream per tenant holds the five tables plans are priced from: pay bands, exchange rates, the reference currency, budget lines and rule defaults. `Projections::Tables` is their only writer, and writes `tenants.pay_bands_changed_at` too.

- **Take the `pay_bands:<tenant>` lock before the stream's.** The previous release still writes bands through `PayBand` callbacks under that lock until predeploy's step 6 reconcile. Taking the two in the other order deadlocks against it.
- **A command catches up first.** `CommandHandler` runs `Reconciliation#catch_up` under the stream lock, so a row the previous release wrote is in the stream before the aggregate decides.
- **`changed?` compares what `held_in_stream` reads back.** Both sides go through `Rows.cast`, as the table types read them. Compare raw values and `"120000.0"` differs from `120000.00`, so every run records a change.
- **`PlanningRuleDefaultCleared` comes from the reconciler only.** No tool clears a rule default today, and none is added here.
- **`updated_by_id` belongs to the previous release.** The projection clears it, and the reconciler maps a row that still holds one to its account's person. `EditorNames` reads `updated_by_person_id`, and the account's person for a row the previous release changed since the last reconcile.
- **The figures stay in the stream for good, unencrypted.** They name no person, so forgetting leaves them alone. Events name their actor by person id only (`changed_by_id`).
- **The move carries today's rules exactly.** A rule about one row stays a validation on its model; the aggregate holds only the rules that span rows, with today's messages.
- **The history reads the whole stream.** A removal carries only its row's id, so `TenantPlanningInputs::History` folds every event forward to know what each change replaced. The screens on the pay band, rates and budget pages and the `tenants_planning_inputs_history` tool read it, admins only. It never shows inside a plan.
