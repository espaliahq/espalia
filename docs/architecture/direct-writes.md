# Direct writes

Every table is written by a projection from events, or it is not. This page lists the writes that are not: who makes them, from where, and whether the table should stay plain state or move to events. It is the catalogue part 2a of [#539](https://github.com/espaliahq/espalia/issues/539) asked for. Part 2b works through the recommendations; nothing here has been moved yet.

Of the 74 tables, 46 are read models. The other 28 are below, with the columns on read-model tables that something besides their projection writes.

## How the list was made

A test run records every database write, then a rake task reports on them.

```bash
WRITE_CATALOGUE=1 bin/rails test:all
bin/rails development:write_catalogue
```

`test/support/write_catalogue.rb` subscribes to `sql.active_record` and keeps each `INSERT`, `UPDATE` and `DELETE` with its table, its columns, the projection it ran inside (if any) and the nearest frame in `app/` or `lib/`. A write a test makes, even from a stub, has no site. A run first empties `tmp/write_catalogue/`, then each worker writes `<pid>.json` there. The rake task merges them into `tmp/write_catalogue/report.md` and prints the findings.

It is off unless `WRITE_CATALOGUE=1`, so CI and the precommit don't pay for it. Turned on, it cost about 4% on the non-system suite (349s against 336s). The run behind this page covered every test, system tests included.

**A finding** is a write from our code, outside a projection, to a table whose rows a projection writes, or an update to a column a projection writes. An upsert counts as an update to the columns its `ON CONFLICT … DO UPDATE` sets. The run checks that from what projections actually wrote, so it needs no list of owners. An insert names every column whether it sets it or not, so inserts into `people` and `tenant_users`, whose projections own only columns, are listed under their tables below rather than as findings.

**Text search fills some of the gaps.** The task also searches `app/` and `lib/` for persistence calls (`save`, `update`, `create`, `destroy`, `upsert_all` and the rest) and lists those no recorded write ran beneath. These are marked *unreached* below: the suite never ran them, so only reading the code says what they write. The search misses calls written as `each(&:destroy!)` or through `public_send`, so its counts are a floor.

| | Count |
|---|---|
| Ruby files in `app/` and `lib/` | 1,507 |
| Files a recorded write ran through | 432 |
| Files with a persistence call | 80 |
| Of those, files the run wrote through nowhere | 2 (`lib/tasks/admin.rake`, `lib/tasks/bench.rake`) |
| Persistence calls found by text search | 368 |
| Of those, never reached | 10 |

The two unreached files are a console task that creates an admin and a benchmark. 1,075 files ran no write at all; most are views, components, policies and queries, which have nothing to write.

## Findings

These are writes around a projection. None are fixed here.

| Table or column | Written from | Why it matters | Suggested for 2b |
|---|---|---|---|
| `framework_capability_categories.deficit_threshold` | `lib/tasks/seed_framework.rake:166` | Sets a category's threshold on the read model after the framework is published. A rebuild of `frameworks/published_state` loses it. | Dispatch the command that sets it, or set it before publishing. Looks like a real bug in the seed. |
| `framework_explorer_graphs` | `Frameworks::ExplorerGraph#store` (`app/contexts/frameworks/explorer_graph.rb:37`), on every load that finds no row | The repository writes the snapshot, and `PublishedState.reset!` deletes it. A missing row is rebuilt from the stream on the next load, so nothing is lost, but the table has two writers. | Declare it a repository cache owned by `ExplorerGraph`, and leave it out of `PublishedState.reset!`, or keep the delete and say why. |
| `people.manager_id`, `job_title`, `status` | HiBob adapter: `sync_people_with_org_graph` (line 169), `save_person` (507), `deactivate_removed` (678) | `org_graph/people_columns` owns these once a tenant is cut over. The adapter writes them only before cut-over, by design. | Remove the pre-cut-over path once every tenant is cut over. |
| `people.manager_id` | `lib/tasks/calibration_history_seed.rb:197` | A development seed moves reporting lines on the row and records the reporting manager beside it. | Move the seed to the Org Graph command, so a cut-over tenant's seed survives a rebuild. |
| Framework, evidence and assignment read models | `lib/tasks/evidence_suggestions_eval.rb` (lines 99 to 134) | The evaluation builds a throwaway tenant by inserting read-model rows, then rolls the transaction back. Nothing persists. | Keep. Say in the file that it never commits. |

## Plain tables

Each section names the writers the run saw and recommends one of two things: **keep** as plain state, with the reason, or **events**, where the table is a decision someone may need to look back on.

### Event store

`event_store_events` and `event_store_events_in_streams` are the events. RailsEventStore writes them. **Keep.**

### `projection_versions`

`ProjectionVersion.stamp!` and `promote!` record which code version each projection was last rebuilt at. **Keep:** deploy bookkeeping.

### Sign-in and API access

| Table | Writers |
|---|---|
| `users` | Devise; `User.from_google_omniauth`, `update_notification_preference`, `provision_from_person!`; `Person#ensure_user!`; `Settings::ColorSchemesController#update`; `SlackDeliveryMethod#mark_preferences_disclosed`; `SeedAdmin.bootstrap!`; the example and stress seeds; `admin.rake` (*unreached*, lines 15 and 20) |
| `oauth_applications` | `Mcp::ClientRegistrationsController#create`; `Mcp::PruneStaleClientsJob` |
| `oauth_access_grants` | `Oauth::AuthorizationsController#create`; `Mcp::PruneStaleClientsJob` |
| `oauth_access_tokens` | Doorkeeper; `Settings::ConnectedClientsController#destroy`; `Mcp::PruneStaleClientsJob` |
| `mcp_pending_approvals` | `Mcp::RequestHandler#defer_to_in_app_approval`; `Mcp::ApprovalsController#approve` and `#reject` |

**Keep all five.** Devise and Doorkeeper manage them, and their history is login telemetry, not a domain decision. An approved MCP call already runs through an Operation, whose events carry the provenance. `users.global_admin` is the one column with audit weight; it changes only from a console or seed, so it can wait.

### `tenant_users`

| Column | Writers |
|---|---|
| `person_id` | `TenantUser#ensure_person!`; the HiBob adapter's `auto_link_tenant_users`; forgetting (`erase_identifiers`) |
| `slack_user_id` | `Tenant#connect_slack!`, `#disconnect_slack!`; `Slack::Identity#resolve`; `SlackDeliveryMethod#resolve_slack_user_id`; forgetting |
| `role` | `Tenant::UsersController#update`; `Person#ensure_user!` and `User.provision_from_person!` on insert |
| rows | `Person#ensure_user!`, `User.provision_from_person!`, the example and stress seeds |

`org_graph_editor` and `team_planner` belong to `account_grants/account_flags` and were only ever written there, which is what part 1 set out to do.

**Recommendation.** `role` decides who administers a tenant, so it moves to events in [#540](https://github.com/espaliahq/espalia/issues/540). Keep `person_id` and `slack_user_id` as plain links: they join one identity to another and say nothing about what anyone may do.

### `tenants`

| Columns | Writers |
|---|---|
| `hris_config`, `hris_credentials` | `Tenant#update_hris!`, `#disconnect_hris!`; `HrisTitlePreview#save_hris_config!`; the HiBob adapter's `stamp_last_synced` |
| `slack_credentials`, `slack_team_id` | `Tenant#connect_slack!`, `#disconnect_slack!` |
| `feedback_exchange_*`, `inbound_key_id`, `previous_inbound_key_id` | `Tenant#update_feedback_exchange!`, `#disconnect_feedback_exchange!` |
| `ai_config`, `ai_credentials`, `settings` | `Tenant#update_ai_model!`, `#remove_ai_api_key!` |
| `org_graph_config` | `UpdateRetentionPeriod`, `EnableScheduledForgetting`, `DisableScheduledForgetting`, `UpdateStalenessThreshold` |
| `time_zone` | `SetTimeZone` |
| `theme`, `custom_theme`, `settings` | `UpdateTheme` |
| `comparison_config` | `UpdateComparisons` |
| `*_label_translations` | `UpdateScoringVocabulary` |
| `pay_bands_changed_at` | `PayBand` callbacks and `PayBand.reorder!` |
| `org_graph_people_projected_at` | `OrgGraph::PeopleCutover#run`, `#revert!` |
| `person_development_fed_at` | `OrgGraph::PersonDevelopmentCutover#feed!`, `#revert!` |
| rows | the example and stress seeds; the evidence evaluation (rolled back) |

**Recommendation.** Keep credentials, connection settings, theme, time zone and the operational stamps as plain state: they configure the tenant and their past values have no use. Move the retention period and scheduled forgetting (`org_graph_config`) to events, since they decide when people's data is deleted and an admin may need to show who changed them and when. The scoring vocabulary and comparisons are borderline; they change what people read, not what is kept, so keep them unless 2b finds a reader for their history.

### `people`

| Columns | Writers |
|---|---|
| rows, every column | `TenantUser#ensure_person!`; the HiBob adapter's `save_person`; the example and stress seeds; the evidence evaluation (rolled back) |
| `manager_id`, `job_title`, `status` | see Findings |
| identifiers (`name`, `email`, `external_id`, `hris_raw_data`, `forgotten_*`) | forgetting (`erase_identifiers`, `scrub_reports_raw_data`) |

**Recommendation.** Keep. The row holds a person's identifiers, which must be erasable, and the Org Graph streams already hold the facts by reference. Retire the pre-cut-over writes listed under Findings once every tenant is cut over.

### Pay and cost inputs

| Table | Writers |
|---|---|
| `pay_bands` | `Operations::Tenants::PayBandSupport#save_setting!` (add, change), `RemovePayBand`; `PayBand.reorder!` and its position callbacks |
| `exchange_rates` | `save_setting!`, `RemoveExchangeRate` |
| `reference_currencies` | `save_setting!` |
| `budget_lines` | `save_setting!`, `RemoveBudgetLine` |
| `planning_rule_defaults` | `SetPlanningRule` |

Every write goes through an Operation, so each carries the actor in its provenance only while the request lasts. The tables keep `updated_by_id`, the last editor, and nothing before.

**Recommendation: events.** These feed every cost figure in Team Planning. An archived plan freezes a copy of the inputs it used, but a live plan reads the tables as they are now, so today nobody can say what a band was last month or who changed it. This is the first thing 2b should take up, and it is a choice for the product owner: the cost of a new stream against the value of that history.

### HRIS sync working data

| Table | Writers |
|---|---|
| `hris_sync_issues` | `HrisSyncIssue.replace_in_structure`; `Hris::LevelHandover#hand_back!` |
| `hris_unit_parent_proposals` | `Hris::LevelMirror#reparent`, `#forget_unread_parents`, `#forget_parent_readings`, `#forget_every_parent_reading`; three `destroy!` calls the run never reached (*unreached*, lines 239, 242 and 327) |

**Keep.** Each sync rebuilds them from what the HRIS reports; they are a to-do list, not a record. What an admin does about an issue already goes through Org Graph commands.

### Feedback and evidence working data

| Table | Writers |
|---|---|
| `evidence_placement_suggestions` | `Evidence::SuggestPlacementsJob#store`, `#upsert`; `EvidencePlacementSuggestion#decide!`; `EvidenceDiffSubmit#accept_adjusted` |
| `feedback_drafts` | `Slack::Feedback#draft`; `FeedbackDraft#consume!` |
| `feedback_exchange_acks` | `FeedbackExchangeAck.record_all` |
| `feedback_exchange_imports` | `FeedbackExchange::Importer#write`; forgetting (`scrub_exchange_ledger`) |

**Keep.** Suggestions are AI output until someone accepts one, and accepting writes evidence through events. A draft lives until the Slack modal submits it. The exchange tables are a ledger of what was sent and received, used to skip duplicates.

One open question for 2b: `decide!` records who dismissed a suggestion, and why, only on the row. If a dismissal ever needs to stand as history, it belongs on the person's development stream.

### Level comparison groups and snapshots

`LevelComparisonSnapshot.take!` writes both `level_comparison_snapshots` and `level_comparison_groups`, deleting the day's earlier take first. **Keep:** each snapshot is derived from ratings at the moment it is taken, so it can be taken again, and it holds no decision.

### `framework_publications`

`Operations::Frameworks::PublishVersion` inserts a row; `Frameworks::PublishVersionJob` claims and finishes it; `FrameworkPublication.reap_stale!` fails rows a dead job left behind. **Keep:** it tracks a background job. The publish itself is `FrameworkVersionPublished`.

### `plan_encryption_keys`

`PlanKeyStore#insert_key`, `#tombstone`, `#destroy_plan`. **Keep:** these must be deletable, since destroying a key is how a plan's figures are shredded. Events can't be deleted.

### Notifications

| Table | Writers |
|---|---|
| `noticed_events` | `ApplicationNotifier#deliver`; forgetting (`scrub_notifications`, `scrub_feedback_contexts`) |
| `noticed_notifications` | `ApplicationNotifier#deliver`; `NotificationsController#update`, `#read_all`, `#mark_seen`; `Evidence::ConversationReads#mark_read!`; forgetting (`drop_notifications_to`) |

**Keep:** the Noticed gem's delivery queue and read state.

## Unreached persistence calls

Beyond those named above, the text search found these lines the suite never ran a write beneath:

| Line | What it is |
|---|---|
| `app/contexts/frameworks/command_handler.rb:42` | An aggregate's `create`, which publishes an event. Not a database write. |
| `app/contexts/team_planning/command_handler.rb:36` | The same. |
| `lib/tasks/bench.rake:119` | The same, in a benchmark. |
| `app/contexts/frameworks/projections/published_state.rb:434` | `PublishedState` writing a level's new ordinal. |
| `app/contexts/person_development/projections/current_assessment.rb:296` | `CurrentAssessment` flagging ratings on a split capability. |

The last two are projections' own writes, so they are not direct writes, but no test runs them.
