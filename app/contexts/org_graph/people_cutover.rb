# frozen_string_literal: true

# Moves one tenant's `job_title`, `manager_id` and `status` from the HRIS
# sync to {OrgGraph::Projections::PeopleColumns}, or back.
#
# The cut-over records every person who has no stream yet, from their row,
# then rebuilds the columns from the streams and compares them with the rows
# as they stood. It commits only when nothing differs, or when the operator
# accepts the streams' values. Everything runs in one transaction, so a dry
# run is the same work rolled back.
#
# @example
#   cutover = OrgGraph::PeopleCutover.new(tenant)
#   cutover.run(apply: false) # => #<data Report ...>
#   cutover.run(apply: true)
#   cutover.revert!
class OrgGraph::PeopleCutover
  # What a run found and did. Ids only, never names or emails.
  #
  # @!attribute recorded [Array<String>] people recorded from their row
  # @!attribute failed [Hash{String => String}] person id to the reason recording failed
  # @!attribute differences [Hash{String => Array<String>}] column to the ids whose rebuilt value differs
  # @!attribute applied [Boolean] whether the tenant is now cut over
  Report = Data.define(:recorded, :failed, :differences, :applied)

  # Holds off a cut-over of the tenant while the block runs, so a sync that
  # read the flag at its start finishes before the flag can change. Any
  # number of holders can overlap. The tenant is reloaded once the lock is
  # held, so the block reads the flag as the last cut-over or revert left it.
  #
  # @param tenant [Tenant]
  # @yield the work that must not straddle a cut-over
  def self.hold_off(tenant)
    connection = ActiveRecord::Base.connection
    connection.select_value(ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_advisory_lock_shared(?)", lock_key(tenant) ]))
    tenant.reload
    yield
  ensure
    connection&.select_value(ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_advisory_unlock_shared(?)", lock_key(tenant) ]))
  end

  # @param tenant [Tenant]
  # @return [Integer]
  def self.lock_key(tenant)
    Zlib.crc32("org-graph-people-cutover:#{tenant.id}")
  end

  # The facts to record someone with from their row. A person carrying an
  # HRIS external id is recorded as that provider's; anyone else, such as
  # someone added by hand or on first sign-in, as Espalia's.
  #
  # @param person [Person]
  # @return [Hash] keywords for {OrgGraph::CommandHandler#record_person}
  def self.row_facts(person)
    held = person.external_id.present? && OrgGraph::PersonAggregate::PROVIDERS.include?(person.hris_source)
    { provider: held ? person.hris_source : "espalia", effective_on: Date.current,
      employment_status: OrgGraph::Projections::PeopleColumns.employment_status(person.status),
      title: person.job_title, manager_id: person.manager_id == person.id ? nil : person.manager_id }
  end

  # @param tenant [Tenant]
  # @param event_store [RailsEventStore::Client]
  def initialize(tenant, event_store: Rails.configuration.event_store)
    @tenant = tenant
    @event_store = event_store
  end

  # @param apply [Boolean] commit the cut-over when it is clean; false rolls everything back
  # @param accept_stream [Boolean] commit even when a column differs, taking the stream's value
  # @return [Report]
  def run(apply:, accept_stream: false)
    report = nil
    ActiveRecord::Base.transaction do
      @tenant.lock!
      raise ArgumentError, "Tenant is already cut over" if @tenant.org_graph_people_projected?
      raise "A sync is running for this tenant; try again once it ends" unless exclusive_lock

      ActsAsTenant.with_tenant(@tenant) do
        before = snapshot
        recorded, failed = record_unrecorded
        @tenant.update!(org_graph_people_projected_at: Time.current)
        rebuild
        differences = compare(before, snapshot)

        applied = apply && failed.empty? && (differences.empty? || accept_stream)
        report = Report.new(recorded:, failed:, differences:, applied:)
      end
      raise ActiveRecord::Rollback unless report.applied
    end
    @tenant.reload
    report
  end

  # Hands the columns back to the HRIS sync. The next sync writes them as it
  # did before the cut-over; the streams keep everything they hold.
  def revert!
    ActiveRecord::Base.transaction do
      raise "A sync is running for this tenant; try again once it ends" unless exclusive_lock

      @tenant.update!(org_graph_people_projected_at: nil)
    end
  end

  private

  def exclusive_lock
    sql = ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_try_advisory_xact_lock(?)", self.class.lock_key(@tenant) ])
    ActiveRecord::Base.connection.select_value(sql)
  end

  def snapshot
    Person.pluck(:id, *OrgGraph::Projections::PeopleColumns::COLUMNS).to_h { |id, *values| [ id, values ] }
  end

  def compare(before, after)
    differences = Hash.new { |all, column| all[column] = [] }
    before.each do |id, values|
      OrgGraph::Projections::PeopleColumns::COLUMNS.each_with_index do |column, index|
        differences[column] << id unless values[index] == after.fetch(id)[index]
      end
    end
    differences.to_h { |column, ids| [ column, ids.sort ] }
  end

  def rebuild
    OrgGraph::Projections::PeopleColumns.reset!(tenant: @tenant)
    Projections::Replayer.replay(projection_class: OrgGraph::Projections::PeopleColumns, tenant: @tenant,
                                 event_store: @event_store)
  end

  def record_unrecorded
    handler = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM, repository: OrgGraph::Repository.new(event_store: @event_store))
    recorded = []
    failed = {}

    AuditMetadata.with(acting_via: :system, correlation_id: SecureRandom.uuid_v7) do
      AuditMetadata.wrap_event_store do
        Person.where.not(id: recorded_ids).find_each do |person|
          ActiveRecord::Base.transaction(requires_new: true) { handler.record_person(person.id, **self.class.row_facts(person)) }
          recorded << person.id
        rescue => e
          failed[person.id] = e.message
        end
      end
    end
    [ recorded.sort, failed ]
  end

  def recorded_ids
    OrgGraph::Projections::PeopleColumns.recorded_person_ids(@tenant)
  end
end
