# Runbook: Feed a tenant's Person Development from the Org Graph

Use this to move a tenant's framework assignments, role and level moves, offboarding and reporting managers from the HRIS sync to the Org Graph (story 9.1). Afterwards `OrgGraph::SyncHandlers::PersonDevelopmentFeed` reconciles a person's Person Development stream on every change to their title, level, manager or employment, and `OrgGraph::PersonDevelopmentSweepJob` reconciles everyone after each sync. The sync no longer assigns or moves anyone itself (Pass 5), and Pass 3b offboards only Espalia-held people.

Only HRIS-held people are fed. Someone Espalia holds keeps the assignment people gave them.

## Before you start

The tenant's people must be cut over first ([org-graph-people-cutover.md](org-graph-people-cutover.md)); the cut-over refuses otherwise.

The cut-over and its revert refuse to run while that tenant's sync is running. If one says `A sync is running`, wait for the sync to end and run it again. The cut-over also refuses while `person_development/current_assessment`, `assessment_cycles/current_state` or `frameworks/published_state` is rebuilt; run it again once the rebuild ends.

No deploy step: the change adds one nullable column and no projection.

## Steps

1. Dry-run it for one tenant:

   ```bash
   bin/rails "org_graph:person_development:cut_over[<tenant id>]"
   ```

   It reconciles every HRIS-held person without issuing anything and prints, for each kind of change, how many people it would touch and their ids, never names or emails:
   - **clear manager**: people whose HRIS recorded that they have no manager while Person Development still holds one. The old sync never cleared a lost manager, so these are expected. Before this release a withheld `reportsTo` was written as "no manager", so check each id against HiBob before you confirm them. If HiBob names a manager for one, stop: the next sync cannot correct it, so raise it before cutting over.
   - anything else, marked **(unexpected)**: an assignment, move or offboarding the old sync should already have made. Any of these stops the cut-over.
   - **could not be read**: each id with its reason. Any entry here stops the cut-over too.

   It ends with a `confirmation:` code, a digest of the manager clears' ids.

2. If there are unexpected changes, look up the ids in a console. Usually the old sync could not apply a mapping (an unmapped title, a missing level) or the person changed since the last sync. Fix the mapping, or run a sync, then dry-run again.

3. Apply it, passing the confirmation the dry run printed:

   ```bash
   bin/rails "org_graph:person_development:cut_over[<tenant id>,<confirmation>]"
   ```

   It recomputes the changes and refuses unless the same people's managers would be cleared and nothing unexpected appeared. If it refuses, dry-run it again and check the new ids. It ends `fed from the Org Graph: yes` once it has cleared those managers and kept the cut-over.

4. Run a sync. The job log's `person_development=` lists what the handler did during the sync, and a `[OrgGraph::PersonDevelopmentSweep]` line follows with the sweep's counts. Both should be empty for a tenant whose people did not change, with `errors` at 0.

## What changes for a fed tenant

- A new title or level reaches Person Development as one role or level change, even when both change in one sync.
- A leaver is withdrawn from the open cycle, then unassigned, when their `PersonLeft` is written. A sync the absence brake holds writes no `PersonLeft` for the people HiBob stopped returning, so it withdraws none of them. Someone HiBob still returns as inactive is a leaver all the same.
- A returner is assigned again from their current title.
- A manager is recorded when the HRIS names one, and cleared only when the HRIS itself recorded none. A withheld or unreadable manager field leaves it alone.
- A title mapping edited between syncs lands with the next sync's sweep.
- A command the domain refuses rolls back alone, is logged, and is counted under `errors`; the sweep tries again after the next sync.
- While a projection the feed reads is rebuilt, every reconcile is refused. The sweep skips everyone, since the rebuild empties the assignments it picks from, and counts them under `skipped_while_rebuilding`; the next sync's sweep catches them up.

## Reverting

```bash
bin/rails "org_graph:person_development:revert[<tenant id>]"
```

The next sync assigns, moves and offboards people as it did before. No data step is needed. Cutting over again dry-runs the comparison afresh.
