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
    @tenant.update!(org_graph_people_projected_at: nil)
  end

  private

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

  # A person carrying an HRIS external id is recorded as that provider's;
  # anyone else, such as someone added by hand or on first sign-in, as
  # Espalia's.
  def record_unrecorded
    handler = OrgGraph::CommandHandler.new(repository: OrgGraph::Repository.new(event_store: @event_store))
    recorded = []
    failed = {}

    AuditMetadata.with(acting_via: :system, correlation_id: SecureRandom.uuid_v7) do
      AuditMetadata.wrap_event_store do
        Person.where.not(id: recorded_ids).find_each do |person|
          ActiveRecord::Base.transaction(requires_new: true) { handler.record_person(person.id, **row_facts(person)) }
          recorded << person.id
        rescue => e
          failed[person.id] = e.message
        end
      end
    end
    [ recorded.sort, failed ]
  end

  def recorded_ids
    Person.pluck(:id).select do |id|
      @event_store.read.stream(EventStreamNaming.person_stream(id)).first.is_a?(OrgGraph::Events::PersonRecorded)
    end
  end

  def row_facts(person)
    held = person.external_id.present? && OrgGraph::PersonAggregate::PROVIDERS.include?(person.hris_source)
    { provider: held ? person.hris_source : "espalia", effective_on: Date.current,
      employment_status: person.status == "inactive" ? "left" : "employed",
      title: person.job_title, manager_id: person.manager_id == person.id ? nil : person.manager_id }
  end
end
