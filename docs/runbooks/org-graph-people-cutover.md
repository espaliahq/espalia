# Runbook: Cut a tenant's people columns over to the Org Graph

Use this to move a tenant's `people.job_title`, `manager_id` and `status` from the HRIS sync to the Org Graph person streams (story 1.4). Afterwards `OrgGraph::Projections::PeopleColumns` is the only writer of those three columns, so the row always agrees with the stream. Readers of `people` see no change.

The other columns stay with the sync. Name, email and external id are identifiers and never go in an event. `department` waits for a level mirrored from an HRIS field (6.7). `level_id`, `role_id` and `hris_level_ordinal` are the framework mapping, which E9 moves.

## Before you start

The tenant's first Org Graph sync must have run ([org-graph-first-sync.md](org-graph-first-sync.md)). The cut-over records anyone still missing from their row. If the first sync never ran, it would record everyone that way, as of the cut-over day, and lose HiBob as the source of their first facts.

The sync reads the flag once, at its start, so the cut-over and its revert refuse to run while that tenant's sync is running. If one says `A sync is running`, wait for the sync to end and run it again.

## Deploy

The deploy that ships this projection needs `REBUILD_ON_DEPLOY=org_graph/people_columns`. Events of its types already exist, so predeploy will not stamp it on its own, and `verify` fails without the rebuild. The rebuild is quick and changes nothing: no tenant is cut over yet, and for a tenant that isn't, the projection writes nothing. Remove the variable after the deploy.

## Steps

1. Dry-run it for one tenant. It does the whole cut-over and then rolls it back:

   ```bash
   bin/rails "org_graph:people:cut_over[<tenant id>]"
   ```

   It prints counts and person ids, never names or emails:
   - **recorded from their row**: people with no stream yet, such as someone added by hand or on first sign-in. A person with an HRIS external id is recorded as that provider's, and anyone else as Espalia's.
   - **leavers dated by**: how many inactive people took their leaving date from each source, best first. *hris termination date* is the termination date in the HiBob record the row last stored. *row updated* is the day the row last changed, used when that was before the cut-over day. *cut over* is the cut-over date, for a leaver with no other evidence. Retention counts from this date, so a large *cut over* count means those leavers are kept longer than the tenant's period says.
   - **could not be recorded**: each id with its reason. Any entry here stops the cut-over.
   - **differs from the stream**: for each column, the people whose row disagrees with what their stream rebuilds. Any entry here stops the cut-over too.

2. If there are differences, look up the ids in a console. The usual one is `manager_id`: the sync never clears a manager on the row, while the stream records a lost one. If the stream is right, accept it in step 3. If the row is right, record the correction in the stream first (see *If it goes wrong* in [org-graph-first-sync.md](org-graph-first-sync.md)), then dry-run again.

3. Apply it:

   ```bash
   APPLY=1 bin/rails "org_graph:people:cut_over[<tenant id>]"
   ```

   Add `ACCEPT_STREAM=1` to take the stream's values for the differences the dry run listed. It ends `cut over: yes` when it has kept the cut-over.

4. Run a sync. `errors=` should be 0. A title, manager or status HiBob changed now reaches the row through its event, and someone HiBob stops returning gets `PersonLeft`. After cut-over a failed absence write delays offboarding by one sync and is reported: the person stays active with an entry in `errors`, and the next sync writes their `PersonLeft`. Before cut-over the sync marks them inactive at once.

## Reverting

```bash
bin/rails "org_graph:people:revert[<tenant id>]"
```

The next sync writes the three columns as it did before. No data step is needed, and the streams keep everything. Cutting over again rebuilds the columns from the streams and compares them with the rows again, as in step 1.

A later change removes the flag and the sync's direct writes once every tenant has cut over.
