# Runbook: An existing tenant's first Org Graph sync

Use this when the Org Graph person stream reaches a tenant that already syncs from HiBob. The first sync after the deploy gives every person their starting point. Nothing before it can be reconstructed, so the history starts on that day ([org-graph-design.md → How the sync writes](../team-planning/org-graph-design.md#how-the-sync-writes)).

## What happens

The next HiBob sync writes `PersonRecorded` for every person HiBob returns, inactive people included. Each one has:

- title, level (only when the tenant has a level column) and manager, as HiBob holds them that day;
- employment status `employed`, or `left` for a person HiBob shows as inactive;
- provider `hibob`, effective the day of the sync.

Every later sync writes only what changed: a person HiBob now shows as inactive gets `PersonLeft`, one active again gets `PersonReturned`, and a changed title, level or manager gets its event. Person Development is untouched, and so is everything a user sees.

**Who is not recorded.** People HiBob does not return are not recorded: someone added by hand, or deactivated by an earlier sync because they had left HiBob altogether. Their history starts if HiBob returns them again.

**No deploy step.** No migration runs, and no projection needs a rebuild. Nothing reads the person streams yet; 1.4 adds that.

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

5. Run the sync again, or wait for the next one. Its `org_graph_events=` should be 0, or close to it if someone's title, level or manager changed in between.

## If it goes wrong

The events are immutable, and a person's first `PersonRecorded` is their starting point for good. A sync never records anyone twice, so re-running one is safe. It records whoever is still missing, then writes changes. If a bug wrote wrong facts, fix it and let the next sync write the corrections as changes. Do not delete streams: the design treats a correction as a new fact, never a rewrite.
