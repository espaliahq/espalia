# Runbook: Forget leavers

Use this to turn on a tenant's scheduled forgetting, to forget one leaver on request, and to know what a database restore does to people already forgotten (story 8.2). The design is in [org-graph-design.md → Forgetting a person](../team-planning/org-graph-design.md#forgetting-a-person-r7).

Forgetting erases a leaver's email, external id and raw HRIS payload from their `people` row, replaces their name with "Former member", unlinks their tenant membership from its login and Slack id, deletes their own notifications in the tenant, removes their name from the notifications others received, drops them from their reports' stored HRIS payloads and from skipped feedback-exchange records, destroys their key in every Team Planning plan, and writes `PersonForgotten` to their person stream. It cannot be undone from inside the app. Every command and log line names people by id and gives counts, never a name or an email.

## How a former member reads

Every screen, export, MCP read and report shows a forgotten person as "Former member". The name is stored that way, and a check constraint on `people` holds every forgotten row to it, so a query that plucks the column reads the stand-in too. Name searches skip forgotten people, so typing "former" offers none of them.

A new MCP read must join the audit with a file of its own in `test/integration/forgotten_person_audit/`, walking it with params or exempting it with a reason. A read model that copies a person's name instead of joining `people` would keep the erased name, so join instead.

## What is not erased

Text people wrote stays, by design. Evidence, feedback, comments and alignment notes each belong to two people: the person who wrote them and the person they are about. Forgetting one of them removes that person's name and identifiers and leaves the words, because erasing them would also erase the other person's record. The words can still name or point to the person forgotten. They live in clear in Person Development events.

Nothing more is written about a forgotten person. Every write to their development stream is refused with "this person has been forgotten", on the web and over MCP: new feedback, ratings, comments, links, requests and the rest. Where their feedback was placed stays as it was at the moment they were forgotten, the hub offers no "Edit links" on it, and "Feedback to place" leaves out their unplaced items. A save in the feedback modal that would change a link normally stores nothing ([#624](https://github.com/espaliahq/espalia/issues/624) makes it one transaction).

Two writes still go through, because they carry nothing about the person. A framework publish migrates their ratings and evidence like everyone else's. A cycle can still unenroll them and close around them, and an unenroll's reason is `manual` or `left_company`, never text someone typed ([#610](https://github.com/espaliahq/espalia/issues/610)).

Only the subject counts: feedback a forgotten author wrote about someone still here can still be placed.

The reason someone gives for dismissing an evidence suggestion follows the same rule as a comment. It is stored in clear in the dismissal event on the person's development stream, and the projection copies it to `evidence_placement_suggestions.dismiss_reason`.

Forgetting also settles evidence placement suggestions ([#590](https://github.com/espaliahq/espalia/issues/590)):

- **The person the feedback is about.** Their pending suggestions close inside the erase, through the `PersonForgotten` event, and leave every screen and MCP read. One already accepted or dismissed keeps its decision. No new suggestion is made for them, and every command on an old one is refused. The development stream still holds the closed ones as pending; the refusal keeps the two from drifting.
- **Only the author.** The suggestion stays open, and the person it is about can still accept or dismiss it. Where the author's name was, the hub shows "Former member", the label used everywhere else.
- **People forgotten before this release.** Predeploy's `events:reconcile` closes their pending suggestions too, and closes nothing once it has run. A rebuild of the projection drops the rows of people forgotten before the catch-up that put the table on the streams, since no event records them ([#608](https://github.com/espaliahq/espalia/issues/608)).

A rationale or a dismissal reason is text someone wrote, so it stays, as above.

One limit is known and accepted for now: when both people have been forgotten, the text stays in the events. The author's person id stays in each event and the subject's in the stream's name. Both ids now lead to a "Former member" row, but the words themselves can still name either person.

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

   A tenant admin can run it through the `tenants_forgetting_dry_run` MCP tool too. It prints the count and the person ids due today, and how many are held back as the only admin (below). Look up a few ids in a console if the number surprises you.
3. Turn it on with that count. A tenant admin calls `tenants_enable_scheduled_forgetting` with `confirm_count` set to the dry run's number. If the number has moved since, the call is refused: run the dry run again. The tenant records when it was turned on and by whom.
4. The next run logs `[OrgGraph::Forgetting] scheduled tenant=<id> reason=retention count=<n> held_back=<n> person_ids=…`.

`tenants_disable_scheduled_forgetting` turns it off. A run already going stops before the next person, and anyone already forgotten stays forgotten. A run also reads the retention period afresh for each person, so lengthening it spares anyone it no longer covers. Shortening it, or moving it from never to a number of years, turns the schedule off, since the count it was turned on with no longer holds. Run the dry run again and turn it back on.

### Where the settings live

The period and the schedule are events on the tenant's `TenantSettings` stream, projected to `tenant_retention_settings`, and that row is all a run reads. A tenant with no row reads as seven years, off. The panel shows who turned the schedule on and when, and "a former member" once that admin is forgotten too.

The old keys of `tenants.org_graph_config` are gone. A migration deletes them, and each settings change removes them again in the same transaction. The release before, which still serves during a deploy, writes them back from the stream with each of its own commands. So any keys left always match the stream: the first change in this release removes them.

[#539](https://github.com/espaliahq/espalia/issues/539) Track C moved off the JSON in two deploys, each gated on the one before:

- **c2** stopped reading the JSON and kept writing it, once c1, which put the settings on the stream, served on every web and worker instance.
- **c2b** stopped writing the JSON, removed the reconciler and deleted the keys, once c2 served everywhere.
- **Once c2b is deployed, NO rollback to c1.** c1 reads the JSON alone, and would read the missing keys as the defaults: seven years, off, with any "never" lost. Roll back to c2 instead. Every c2b settings command removes the keys in the same transaction as its events. So a tenant that still has keys has run no c2b command since c2 wrote them, and they equal the stream. Its reconciler then records nothing new: not from a JSON holding none of the keys, and not from keys that match.

A run holds the stream's lock shared, then the tenant row, for each person. A change from either release waits for that person to finish, or the run sees it before the next one.

## Forgetting one leaver on request

Forgetting a single person stays off MCP, so an agent can never hold an irreversible erase. An operator runs it for a tenant admin who asked:

```bash
bin/rails "org_graph:forgetting:forget[<tenant id>,<person id>,<admin's tenant user id>]"
```

- The person must have left. The aggregate refuses anyone else.
- A leaver whose retention period has not ended is refused unless you add `BEFORE_DUE=1`. The event then records `reason: request` and the admin's tenant user id.
- A leaver the HRIS still shows as active, such as a rehire who hasn't started yet, is refused.
- Running it twice is safe: the second run prints `was already forgotten`.
- A leaver who holds the only admin account is refused (below).

## Held back: the only admin

Forgetting erases a person's accounts, so it refuses anyone whose accounts hold every admin the tenant has. Otherwise nobody would be left to run the organisation. A tenant with no admin at all forgets as before.

- **A scheduled run** carries on past them and counts them as `held_back`. It reports a warning with the tenant id and that count, never an id. They stay due, so the warning comes back every day until it's fixed.
- **The dry run** counts them the same way, taking leavers in the run's order. Two due admins and no other admin give a count of one and one held back. The confirm count leaves them out. The dry run assumes everyone before them is forgotten, so if the first admin's erase fails that day, the run forgets the second instead of holding them back.
- **A manual forget** refuses with "This person holds the organisation's only admin account. Make someone else an admin, then forget them."

The refusal rolls back the whole erase, so the person is untouched. To clear it, ask a tenant admin to make someone else an admin. The next run forgets them.

## If a run fails

Each person is one transaction: the row, the membership, the notifications, their key in every plan, the event and the projections that handle it. A run that dies partway leaves each person either forgotten or untouched, and the next run takes whoever is still due. No checkpoint is needed.

- **The HRIS can't be reached**: nobody in that tenant is forgotten that day. The error is reported and the other tenants carry on.
- **The key is missing**: the job fails before touching any tenant.
- **A leaver holds the only admin account**: they're held back and the rest carry on. See *Held back: the only admin*.

## Restoring from a backup

**A restore can undo forgetting.** It brings back the name, email and external id of everyone forgotten after the backup was taken, and removes their `PersonForgotten`. It also brings back their keys in every plan, so what plans held about them reads again until they are forgotten again, which for those below means asking again.

- **People forgotten because their period ended** are forgotten again by the next scheduled run, since their leaving dates are in the restored events. That happens only if the tenant's schedule is on.
- **People forgotten on request before their due date are not forgotten again** after a restore until their own period ends, and nor are their plan keys destroyed. Nothing in the app records the request outside the database you restored.

So the real time to forget includes the backup retention period. Each deployment should state it. After a restore, tell the tenant admins which requests may need making again.

## Notifications

Every notification written from now on carries the person id beside each name it copies, in its params, and the scrub matches on that id. Only notifications written before story 8.2 hold a name with no id. For those legacy rows alone the scrub matches the name within the tenant, so a colleague with the same name loses theirs from those old notifications too, which then read "A colleague" or a similar stand-in. Notifications in other tenants are untouched.

A comment on someone's feedback carries a context line that opens "<name>'s feedback". It carries `feedback_author_id` and `feedback_author_name` beside it, and forgetting that person rewrites the opening to "Former member's feedback". The cut runs the length of the stored name, so a name that itself contains "'s feedback" goes whole. An older one without the id is matched on the name, as above.

A notification built just before an erasure, from a name read before it, can be written just after it. So every notification checks the ids it carries as it is written, waiting for any erasure in its tenant to commit first, and drops the names of anyone forgotten.

The recipient gets the same check. A notification addressed before an erasure but written after it skips any login that no longer holds a membership in its tenant, since erasure unlinks the forgotten person's login there.

A new notifier that copies a person's name must put the id beside it and add the pair to `OrgGraph::Forgetting::NAME_PARAMS`. A list of names beside a list of ids, such as `skipped_names` and `skipped_ids`, goes in `NAME_LIST_PARAMS` instead.
