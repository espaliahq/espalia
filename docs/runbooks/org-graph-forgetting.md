# Runbook: Forget leavers

Use this to turn on a tenant's scheduled forgetting, to forget one leaver on request, and to know what a database restore does to people already forgotten (story 8.2). The design is in [org-graph-design.md → Forgetting a person](../team-planning/org-graph-design.md#forgetting-a-person-r7).

Forgetting erases a leaver's name, email, external id and raw HRIS payload from their `people` row, unlinks their tenant membership from its login and Slack id, deletes their own notifications in the tenant, removes their name from the notifications others received, drops them from their reports' stored HRIS payloads and from skipped feedback-exchange records, and writes `PersonForgotten` to their person stream. It cannot be undone from inside the app. Every command and log line names people by id and gives counts, never a name or an email.

## What is not erased

Free text people wrote is untouched: evidence, comments, feedback and alignment notes can name the person, and they live in clear in Person Development events. Erasing them needs shreddable fields ([#110](https://github.com/espaliahq/espalia/issues/110)). Until that lands, forgetting erases identifiers, not every mention.

Operational facts stay too: title, level, department, positions and dates. In a small team they can still point to one person.

## The key

The row keeps an HMAC of its external id, so a later sync recognises the person without identifying them. The key is `org_graph.forgetting_key` in Rails credentials, or `ORG_GRAPH_FORGETTING_KEY`.

- **Set it before anyone is forgotten**, with `openssl rand -hex 32`.
- **Never rotate it.** A digest can't be recomputed, because the external id is gone. With a new key, the next sync no longer recognises anyone forgotten and creates each of them again from the HRIS.
- Without the key the app still boots, but every forgetting command, the dry run and turning the schedule on all refuse. A sync refuses too, as soon as any row in the tenant holds a digest.

## Turning the schedule on

The schedule ships off for every tenant. `OrgGraph::ForgetDueLeaversJob` runs daily at 02:17 and acts only in tenants that turned it on.

1. Check the retention period on the tenant (`retention_years`, default seven years). A tenant set to never can't turn the schedule on.
2. Run the dry run. It applies the same HRIS check as a real run and erases nothing:

   ```bash
   bin/rails "org_graph:forgetting:dry_run[<tenant id>]"
   ```

   A tenant admin can run it through the `tenants_forgetting_dry_run` MCP tool too. It prints the count and the person ids due today. Look up a few ids in a console if the number surprises you.
3. Turn it on with that count. A tenant admin calls `tenants_enable_scheduled_forgetting` with `confirm_count` set to the dry run's number. If the number has moved since, the call is refused: run the dry run again. The tenant records when it was turned on and by which tenant user.
4. The next run logs `[OrgGraph::Forgetting] scheduled tenant=<id> reason=retention count=<n> person_ids=…`.

`tenants_disable_scheduled_forgetting` turns it off. Anyone already forgotten stays forgotten.

## Forgetting one leaver on request

Forgetting a single person stays off MCP, so an agent can never hold an irreversible erase. An operator runs it for a tenant admin who asked:

```bash
bin/rails "org_graph:forgetting:forget[<tenant id>,<person id>,<admin's tenant user id>]"
```

- The person must have left. The aggregate refuses anyone else.
- A leaver whose retention period has not ended is refused unless you add `BEFORE_DUE=1`. The event then records `reason: request` and the admin's tenant user id.
- A leaver the HRIS still shows as active, such as a rehire who hasn't started yet, is refused.
- Running it twice is safe: the second run prints `was already forgotten`.

## If a run fails

Each person is one transaction: the row, the membership, the notifications, the event and the projections that handle it. A run that dies partway leaves each person either forgotten or untouched, and the next run takes whoever is still due. No checkpoint is needed.

- **The HRIS can't be reached**: nobody in that tenant is forgotten that day. The error is reported and the other tenants carry on.
- **The key is missing**: the job fails before touching any tenant.

## Restoring from a backup

**A restore can undo forgetting.** It brings back the name, email and external id of everyone forgotten after the backup was taken, and removes their `PersonForgotten`.

- **People forgotten because their period ended** are forgotten again by the next scheduled run, since their leaving dates are in the restored events. That happens only if the tenant's schedule is on.
- **People forgotten on request before their due date are not forgotten again** after a restore until their own period ends. Nothing in the app records the request outside the database you restored.

So the real time to forget includes the backup retention period. Each deployment should state it. After a restore, tell the tenant admins which requests may need making again.

## Notifications

Stored notifications copy names by value and hold no person id beside them, so the scrub matches the name within the tenant. A colleague with the same name loses theirs from old notifications too, which then read "A colleague" or a similar stand-in. Notifications in other tenants are untouched.
