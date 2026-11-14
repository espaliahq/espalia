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
  # @!attribute left_on_sources [Hash{String => Integer}] how many leavers recorded
  #   from their row took their leaving date from each source
  Report = Data.define(:recorded, :failed, :differences, :applied, :left_on_sources)

  # The kinds of fact {row_facts} records.
  RECORDED_FACTS = %w[employment_status title manager].freeze

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
  # someone added by hand or on first sign-in, as Espalia's. A leaver leaves
  # on the date {leaving} finds.
  #
  # @param person [Person]
  # @param on [Date] the cut-over date
  # @return [Hash] keywords for {OrgGraph::CommandHandler#record_person}
  def self.row_facts(person, on: Date.current)
    employment_status = OrgGraph::Projections::PeopleColumns.employment_status(person.status)
    { provider: provider_for(person), effective_on: on, employment_status:,
      title: person.job_title, manager_id: person.manager_id == person.id ? nil : person.manager_id,
      **(leaving(person, on:) if employment_status == "left") }
  end

  # When a leaver left, from the best evidence their row holds, shared by
  # the cut-over and a sync so the two agree. Nothing records when a row
  # became inactive, so an inactive row's last update stands in for it, but
  # only from before that day. Any later write moves it, so it can fall
  # after they truly left.
  #
  # @param person [Person]
  # @param on [Date] the day they are first recorded: the cut-over date, or a sign-in or sync after it
  # @return [Hash] :left_on and :left_on_source, one of {OrgGraph::PersonAggregate::LEFT_ON_SOURCES}
  def self.leaving(person, on: Date.current)
    evidence = { "hris_termination_date" => Hris::BaseAdapter.terminated_on(person)&.then { Date.iso8601(it) },
                 "row_updated" => (person.updated_at&.to_date if person.status == "inactive")&.then { it if it < on } }
    source, left_on = evidence.find { |_, date| date && date <= on } || [ "first_recorded", on ]
    { left_on:, left_on_source: source }
  end

  # The provider {OrgGraph::CommandHandler} lets record the person: their
  # HRIS, while it carries their external id and holds each fact recorded,
  # and otherwise Espalia. Facts split between the two can't be recorded in
  # one command, and the refusal names the fact.
  #
  # @param person [Person]
  # @return [String]
  def self.provider_for(person)
    source = person.hris_source if person.external_id.present?
    held = RECORDED_FACTS.all? { OrgFactProvider.provider_for(it) == source }
    held ? source : OrgGraph::StructureAggregate::ESPALIA
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
        recorded, failed, left_on_sources = record_unrecorded(on: Date.current)
        @tenant.update!(org_graph_people_projected_at: Time.current)
        rebuild
        differences = compare(before, snapshot)

        applied = apply && failed.empty? && (differences.empty? || accept_stream)
        report = Report.new(recorded:, failed:, differences:, applied:, left_on_sources:)
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

  def record_unrecorded(on:)
    handler = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM, repository: OrgGraph::Repository.new(event_store: @event_store))
    recorded = []
    failed = {}
    left_on_sources = Hash.new(0)

    AuditMetadata.with(acting_via: :system, correlation_id: SecureRandom.uuid_v7) do
      AuditMetadata.wrap_event_store do
        Person.where.not(id: recorded_ids).find_each do |person|
          facts = self.class.row_facts(person, on:)
          ActiveRecord::Base.transaction(requires_new: true) { handler.record_person(person.id, **facts) }
          recorded << person.id
          left_on_sources[facts[:left_on_source]] += 1 if facts[:left_on_source]
        rescue => e
          failed[person.id] = e.message
        end
      end
    end
    [ recorded.sort, failed, left_on_sources.sort_by { |source, _| OrgGraph::PersonAggregate::LEFT_ON_SOURCES.index(source) }.to_h ]
  end

  def recorded_ids
    OrgGraph::Projections::PeopleColumns.recorded_person_ids(@tenant)
  end
end
