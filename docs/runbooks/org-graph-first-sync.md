# Runbook: An existing tenant's first Org Graph sync

Use this when the Org Graph person stream reaches a tenant that already syncs from HiBob. The first sync after the deploy gives every person their starting point. Nothing before it can be reconstructed, so the history starts on that day ([org-graph-design.md → How the sync writes](../team-planning/org-graph-design.md#how-the-sync-writes)).

## What happens

The next HiBob sync writes `PersonRecorded` for every person HiBob returns, inactive people included. Each one has:

- title, level (only when the tenant has a level column), manager, site, FTE, employment type and start date, as HiBob holds them that day;
- employment status `employed`; `pending` for a hire whose start date is still ahead; or `left`, with the termination date, for a person HiBob shows as inactive;
- provider `hibob`, effective the day of the sync.

Every later sync writes only what changed: a person HiBob now shows as inactive gets `PersonLeft`, one active again gets `PersonReturned`, and a changed title, level or manager gets its event. Person Development is untouched, and so is everything a user sees.

**A tenant recorded before site, FTE, employment type and start dates arrived** gets them on its next sync: up to three events per person (`SiteChanged`, `EmploymentChanged`, `StartDateChanged`), then quiet again. FTE and employment type need the service user to read HiBob's payroll fields; without that permission HiBob leaves them out and nothing is written for them. Each leaver HiBob holds a termination date for (`internal.terminationDate`, which needs the same kind of read access) also gets a `PersonLeft` on that date, correcting the sync day the first sync used.

**Who is not recorded.** People HiBob does not return are not recorded: someone added by hand, or deactivated by an earlier sync because they had left HiBob altogether. Their history starts if HiBob returns them again.

**No deploy step.** No migration runs, and no projection needs a rebuild. No projection reads the events this sync writes yet; 1.4 adds that.

**The HRIS must hold the facts it writes.** Each person command is refused unless its provider holds the fact. Predeploy's `org_graph:claim_hris_facts` hands each configured HRIS its default facts (employment status, title, level, manager, site and employment) before the first sync on a release, and saving the HRIS settings does the same. If a sync's `errors` read `espalia supplies title; change it there`, someone handed that fact to Espalia on purpose, or the person carries no `hibob` external id; set it back with `OrgGraph::StructureCommandHandler#set_fact_provider` only if that was a mistake. The task is safe to run again by hand: `bin/rails org_graph:claim_hris_facts`.

## Steps

1. Deploy as usual.
2. Wait for the scheduled sync (`HrisSyncAllTenantsJob`, every 6 hours), or start one now. Either press **Sync now** on **Integrations → HRIS**, or run this in a console:

   ```ruby
   HrisSyncJob.perform_later(Tenant.find("<tenant id>"))
   ```

3. Read the sync's log line. `org_graph_events=` should be close to the number of people HiBob returned, and `errors=` should be 0. A person whose recording failed is listed in the result's `errors` with their `person_id`. The next sync tries them again, since they are still unrecorded.
4. Check the count in a console:

   ```ruby
   tenant = Tenant.find("<tenant id>")
   ActsAsTenant.with_tenant(tenant) do
     sql = ActiveRecord::Base.sanitize_sql_array([
       "SELECT COUNT(DISTINCT stream) FROM event_store_events_in_streams WHERE stream LIKE ?",
       "#{EventStreamNaming.person_stream('')}%"
     ])
     [ Person.where(hris_source: "hibob").count, ActiveRecord::Base.connection.select_value(sql) ]
   end
   ```

   The two numbers should match, less anyone HiBob stopped returning before the deploy.

5. Run the sync again, or wait for the next one. Its `org_graph_events=` should be 0, or close to it if someone's facts or status changed in between.

## If it goes wrong

The events are immutable, and a person's first `PersonRecorded` is their starting point for good. A sync never records anyone twice, so re-running one is safe. It records whoever is still missing, then writes changes. If a bug wrote wrong facts for someone employed, fix it and let the next sync write the corrections as changes. The sync never compares a leaver's facts, so correct those in a console, inside the tenant. `change_title`, `change_level` and `change_manager` write the correction and leave the person's status as it is:

```ruby
tenant = Tenant.find("<tenant id>")
ActsAsTenant.with_tenant(tenant) do
  person = Person.find("<person id>")
  OrgGraph::CommandHandler.new.change_title(person.id, "Designer", provider: "hibob", effective_on: Date.current)
end
```

Do not delete streams: the design treats a correction as a new fact, never a rewrite.
