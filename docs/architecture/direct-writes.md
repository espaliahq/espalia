# Direct writes

Every table is written by a projection from events, or it is not. This page lists the writes that are not: who makes them, from where, and whether the table should stay plain state or move to events. It is the catalogue part 2a of [#539](https://github.com/espaliahq/espalia/issues/539) asked for. Part 2b works through the recommendations; nothing here has been moved yet.

Of the 74 tables, 47 are read models. The other 27 are below, with the columns on read-model tables that something besides their projection writes.

The rules now live in [`config/write_ownership.yml`](../../config/write_ownership.yml), one entry per table, and CI holds every write to them. This page keeps the reasons at length.

## Declaring a table or a writer

Each entry is keyed by its table and has an `owner`:

| `owner` | Means | Also takes |
|---|---|---|
| a projection's name, such as `org_graph/structure` | That projection writes the table. | `columns`, when it owns only those |
| `event_store` | RailsEventStore writes it. | nothing |
| `plain` | Plain state, not written from events. | `reason`, required |

`writers` lists the files in `app/` or `lib/` allowed to write the table outside its owner. Where a projection owns only some `columns`, a writer may still insert rows, but only a file also in `column_writers` may update those columns. A projection's table with writers, a table whose projection owns only some columns, and a plain table each need a `reason` of one line. Write an issue as its full link: in YAML, ` #` starts a comment and cuts the reason short.

```yaml
hris_sync_issues:
  owner: plain
  reason: Each sync rebuilds them from what the HRIS reports; a to-do list, not a record.
  writers:
    - app/integrations/hris/level_handover.rb
    - app/models/hris_sync_issue.rb
```

**A new table** gets an entry in the same PR as its migration, or `test/db/write_ownership_test.rb` fails. The test also fails on a table declared twice, an entry whose table is gone, an owner that is no projection, a column the table doesn't have, a missing reason, or a writer that is no file in `app/` or `lib/`.

**A table moving onto a stream** changes its entry from `plain` to its projection. Leave the old writers listed, with the reason, until the PR that stops their writes removes them.

**A new writer** is added to its table's `writers`. CI's `test` and `system-test` jobs each run their suite with `WRITE_CATALOGUE=1`, then `bin/rails write_ownership:check`, which fails on:

- a write from a file the entry doesn't name;
- a projection writing a table another projection owns;
- a projection writing a column its entry doesn't give it, or deleting rows of a table where it owns only columns;
- a writer updating a column a projection owns, unless the file is among `column_writers`.

A write a test makes itself is never checked. The check matches files, not lines, so moving code within a file doesn't break it. The system tests' writes are recorded too, including those the app server makes while a browser drives it, as it runs in the same process. To check everything locally, run the whole suite with `WRITE_CATALOGUE=1 bin/rails test:all`, then the check.

**A write on a path no test runs** is mostly caught by `lint`, with the blind spots below. `Espalia/WritesMustBeDeclared`, a RuboCop cop, flags a persistence call such as `update!`, `create` or `delete_all` in any `.rb` file under `app/operations`, `app/controllers`, `app/jobs`, `app/integrations`, `app/contexts`, `app/queries`, `app/policies`, `app/views` or `app/components`, in a file no entry names among its `writers` or `column_writers`. A file under a `projections/` directory or `app/read_models` passes by its path, as a projection writes only its own tables and the recorded check holds it to them. So does a command on an aggregate the repository yields (`@repository.with_plan(id) { |plan| plan.create(...) }`), which records an event, not a row. It reads those names from `config/write_ownership.yml`, so there is no second list. It matches by method name, so it can't tell which table a call writes: a named file passes whatever it writes, and the recorded check holds each write to its own table. It matches a write by the method name of a direct call on a receiver, in `.rb` files only, so anything that writes another way is outside it. For example: a library method (Noticed's `mark_as_read`, Doorkeeper's `revoke`); a call with no receiver (`user.instance_eval { update!(...) }`), which it skips by design; a method passed as a symbol or through `send` (`Person.where(...).each(&:destroy!)`); `delete` or `insert` on an association (`tenant.people.delete(person)`), as those count only on a constant or a query built from one; or an ERB template. The recorded check covers any of these that a test reaches. Neither check holds the event store's own tables to their writers: the recorded check skips them, and the cop passes any declared file (see [Event store](#event-store) below). `update` counts on any receiver but a literal and the request's and the view's own objects called by name (`session`, `cookies`, `flash`, `params`, `headers`, `turbo_stream`); a local with one of those names counts, as it may hold a record. An aggregate's command stops passing when a nearer block rebinds its name. It doesn't follow an assignment, though: a block argument reassigned inside a repository block still passes (`|plan| plan = Plan.find(x); plan.update!`). A call it flags that writes no table, such as an API client's `messages.create`, takes an inline `# rubocop:disable Espalia/WritesMustBeDeclared -- <why>`, never an `Exclude:` entry.

## How the list was made

A test run records every database write, then a rake task reports on them.

```bash
WRITE_CATALOGUE=1 bin/rails test:all
bin/rails development:write_catalogue
```

`test/support/write_catalogue.rb` subscribes to `sql.active_record` and keeps each `INSERT`, `UPDATE` and `DELETE` with its table, its columns, the projection it ran inside (if any) and the nearest frame in `app/` or `lib/`. A write a test makes, even from a stub, has no site. A run first empties `tmp/write_catalogue/`, then each worker writes `<pid>.json` there. The rake task merges them into `tmp/write_catalogue/report.md` and prints the findings.

It is off unless `WRITE_CATALOGUE=1`. CI's `test` and `system-test` jobs turn it on, which cost about 4% on the non-system suite (349s against 336s); the precommit leaves it off. The run behind this page covered every test, system tests included.

**A finding** is a write from our code, outside a projection, to a table whose rows a projection writes, or an update to a column a projection writes. An upsert counts as an update to the columns its `ON CONFLICT … DO UPDATE` sets. The run checks that from what projections actually wrote, so it needs no list of owners. An insert names every column whether it sets it or not, so inserts into `people` and `tenant_users`, whose projections own only columns, are listed under their tables below rather than as findings.

**Text search fills some of the gaps.** The task also searches `app/` and `lib/` for persistence calls (`save`, `update`, `create`, `destroy`, `upsert_all` and the rest) and lists those no recorded write ran beneath. These are marked *unreached* below. The suite may still run such a call without writing, as a failed validation or an unchanged save writes nothing, so only reading the code says what it writes. The search misses calls written as `each(&:destroy!)` or through `public_send`, so its counts are a floor.

| | Count |
|---|---|
| Ruby files in `app/` and `lib/` | 1,507 |
| Files a recorded write ran through | 432 |
| Files with a persistence call | 80 |
| Of those, files the run wrote through nowhere | 1 (`lib/tasks/bench.rake`) |
| Persistence calls found by text search | 368 |
| Of those, with no recorded write beneath them | 4 |

The unreached file is a benchmark. 1,075 files ran no write at all; most are views, components, policies and queries, which have nothing to write.

## Findings

These are writes around a projection. None are fixed here.

| Table or column | Written from | Why it matters | Suggested for 2b |
|---|---|---|---|
| `framework_capability_categories.deficit_threshold` | Was `lib/tasks/seed_framework.rake`, after publishing | A rebuild of `frameworks/published_state` lost the threshold. | Fixed in [#571](https://github.com/espaliahq/espalia/issues/571): the seed dispatches `set_category_deficit_threshold`. A threshold seeded before then has no event, and a rebuild still loses it. |
| `people.manager_id`, `job_title`, `status` | HiBob adapter: `sync_people_with_org_graph` (line 169), `save_person` (507), `deactivate_removed` (678) | `org_graph/people_columns` owns these once a tenant is cut over. The adapter writes them only before cut-over, by design. | Remove the pre-cut-over path once every tenant is cut over. |
| `people.manager_id` | `lib/tasks/calibration_history_seed.rb:197` | A development seed moves reporting lines on the row and records the reporting manager beside it. | Move the seed to the Org Graph command, so a cut-over tenant's seed survives a rebuild. |
| Framework, evidence and assignment read models | `lib/tasks/evidence_suggestions_eval.rb` (lines 99 to 134) | The evaluation builds a throwaway tenant by inserting read-model rows, then rolls the transaction back. Nothing persists. | Keep. Say in the file that it never commits. |

## Plain tables

Each section names the writers the run saw and recommends one of two things: **keep** as plain state, with the reason, or **events**, where the table is a decision someone may need to look back on.

### Event store

`event_store_events` and `event_store_events_in_streams` are the events. RailsEventStore writes them. **Keep.** The one other writer is `app/contexts/team_planning/name_sealing.rb`, the sanctioned rewrite that seals plan names ([#209](https://github.com/espaliahq/espalia/issues/209)). The recorded check doesn't watch the event store's own tables, and the lint cop checks files, not tables: it passes a file any entry names, or one on a projection path, whatever that file writes. So nothing in CI holds `event_store_events` to this one writer; review does.

### `projection_versions`

`ProjectionVersion.stamp!` and `promote!` record which code version each projection was last rebuilt at. **Keep:** deploy bookkeeping.

### Sign-in and API access

| Table | Writers |
|---|---|
| `users` | Devise; `User.from_google_omniauth`, `update_notification_preference`, `provision_from_person!`; `Person#ensure_user!`; `Settings::ColorSchemesController#update`; `SlackDeliveryMethod#mark_preferences_disclosed`; `SeedAdmin.bootstrap!`; the example and stress seeds; `admin.rake` |
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
| `role` | `account_grants/account_flags` from `AccountRoleSet`; `Person#ensure_user!`, `User.provision_from_person!` and the seeds on insert, each recording the role at once |
| rows | `Person#ensure_user!`, `User.provision_from_person!`, the example and stress seeds |

`org_graph_editor` and `team_planner` belong to `account_grants/account_flags` and were only ever written there, which is what part 1 set out to do.

**Recommendation.** `role` decides who administers a tenant, so it moved to events in [#540](https://github.com/espaliahq/espalia/issues/540). Keep `person_id` and `slack_user_id` as plain links: they join one identity to another and say nothing about what anyone may do.

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
| `pay_bands_changed_at` | `tenant_planning_inputs/tables`, from the TenantPlanningInputs stream |
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

**Moved to events** in Track A of [#539](https://github.com/espaliahq/espalia/issues/539). `pay_bands`, `exchange_rates`, `reference_currencies`, `budget_lines` and `planning_rule_defaults` are now written only by `tenant_planning_inputs/tables`, from the tenant's TenantPlanningInputs stream. Each change names its actor (`changed_by_id`) and keeps the figures, so a band's past values and who changed them can be read back: the history pages beside each table and the `tenants_planning_inputs_history` tool show them, to tenant admins only. [app/contexts/tenant_planning_inputs/AGENTS.md](../../app/contexts/tenant_planning_inputs/AGENTS.md) holds the rules the move keeps.

### HRIS sync working data

| Table | Writers |
|---|---|
| `hris_sync_issues` | `HrisSyncIssue.replace_in_structure`; `Hris::LevelHandover#hand_back!` |
| `hris_unit_parent_proposals` | `Hris::LevelMirror#reparent`, `#forget_unread_parents`, `#forget_parent_readings`, `#forget_every_parent_reading`; one `destroy!` with no recorded write (*unreached*, line 327) |

**Keep.** Each sync rebuilds them from what the HRIS reports; they are a to-do list, not a record. What an admin does about an issue already goes through Org Graph commands.

### Feedback and evidence working data

| Table | Writers |
|---|---|
| `feedback_drafts` | `Slack::Feedback#draft`; `FeedbackDraft#consume!` |
| `feedback_exchange_acks` | `FeedbackExchangeAck.record_all` |
| `feedback_exchange_imports` | `FeedbackExchange::Importer#write`; forgetting (`scrub_exchange_ledger`) |

**Keep.** A draft lives until the Slack modal submits it. The exchange tables are a ledger of what was sent and received, used to skip duplicates.

`evidence_placement_suggestions` left this list in [#539](https://github.com/espaliahq/espalia/issues/539) c3: the `person_development/evidence_suggestions` projection writes it from the development stream, so a dismissal and who made it now stand as history.

### Level comparison groups and snapshots

`LevelComparisonSnapshot.take!` writes both `level_comparison_snapshots` and `level_comparison_groups`, deleting the day's earlier take first. **Keep:** each snapshot is derived from ratings at the moment it is taken, so it can be taken again, and it holds no decision.

### `framework_explorer_graphs`

`Frameworks::ExplorerGraph#store` writes the snapshot, from the repository after each framework write and from `#rebuild` on a load that finds no current row. **Keep:** it is a cache of the framework's stream, so a missing or stale row costs one rebuild and loses nothing. Each row records the last stream event it has seen (`last_event_id`), and `#load` treats a row behind its stream as missing. `PublishedState.reset!` once deleted it through the framework's cascade, which made each rebuild of that projection throw away every snapshot ([#539](https://github.com/espaliahq/espalia/issues/539) c7).

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

The text search found these lines with no recorded write beneath them:

| Line | What it is |
|---|---|
| `app/contexts/frameworks/command_handler.rb:42` | An aggregate's `create`, which publishes an event. Not a database write. |
| `app/contexts/team_planning/command_handler.rb:36` | The same. |
| `lib/tasks/bench.rake:119` | The same, in a benchmark. |
| `app/integrations/hris/level_mirror.rb:327` | `Hris::LevelMirror#retire_units` dropping a retiring unit's proposed parent. A retiring unit is never read in that sync, so `#forget_unread_parents` has already dropped it. |
