# frozen_string_literal: true

# Synchronous projection of the operational columns of `people` from the
# person streams: `job_title`, `manager_id` and `status`.
#
# Writes only those columns, and only for a tenant cut over to the Org Graph
# ({Tenant#org_graph_people_projected?}). Until then the HRIS sync writes
# them and this projection writes nothing. The identifier columns, and the
# framework mapping the sync derives, stay with the sync.
#
class OrgGraph::Projections::PeopleColumns
  # Stable identifier used as the natural key in `projection_versions.name`.
  PROJECTION_NAME = "org_graph/people_columns"

  # Bump when `reset!` or any handler would write different state from the
  # same event payload than before.
  CODE_VERSION = 1

  COLUMNS = %w[job_title manager_id status].freeze

  STATUS = { "pending" => "active", "employed" => "active", "left" => "inactive" }.freeze
  private_constant :STATUS

  # The employment status a `people.status` (or a provider's active flag,
  # mapped the same way) stands for.
  #
  # @param status [String] "active" or "inactive"
  # @return [String] "employed" or "left"
  def self.employment_status(status)
    status == "inactive" ? "left" : "employed"
  end

  # The people whose stream holds their `PersonRecorded`, in one query.
  #
  # @param tenant [Tenant]
  # @return [Array<String>] person ids
  def self.recorded_person_ids(tenant)
    prefix = EventStreamNaming.person_stream("", tenant:)
    sql = ActiveRecord::Base.sanitize_sql_array([ <<~SQL, "#{prefix}%", OrgGraph::Events::PersonRecorded.name ])
      SELECT DISTINCT streams.stream FROM event_store_events_in_streams streams
      JOIN event_store_events events ON events.event_id = streams.event_id
      WHERE streams.stream LIKE ? AND events.event_type = ?
    SQL
    ActiveRecord::Base.connection.select_values(sql).map { it.delete_prefix(prefix) }
  end

  # @return [Array<Class>]
  def self.handled_events
    [ OrgGraph::Events::PersonRecorded, OrgGraph::Events::TitleChanged, OrgGraph::Events::ManagerChanged,
      OrgGraph::Events::PersonJoined, OrgGraph::Events::PersonLeft, OrgGraph::Events::PersonReturned ]
  end

  # Clears the projected columns of a cut-over tenant's recorded people, the
  # ones a replay writes back. Leaves anyone without a stream, and a tenant
  # the sync still writes, alone.
  #
  # @param tenant [Tenant]
  def self.reset!(tenant:)
    return unless tenant.reload.org_graph_people_projected?

    ActsAsTenant.with_tenant(tenant) do
      Person.where(tenant_id: tenant.id, id: recorded_person_ids(tenant))
            .update_all(job_title: nil, manager_id: nil, status: "active")
    end
  end

  # @param event [RubyEventStore::Event]
  def call(event)
    tenant = ActsAsTenant.current_tenant
    tenant = Tenant.find(event.metadata[:tenant_id]) unless tenant&.id == event.metadata[:tenant_id]
    # Read the flag from the database: a request's tenant may predate a cut-over.
    return unless Tenant.where(id: tenant.id).where.not(org_graph_people_projected_at: nil).exists?

    ActsAsTenant.with_tenant(tenant) do
      Person.where(id: event.data[:person_id]).update_all(columns(event).merge(updated_at: Time.current))
    end
  end

  private

  def columns(event)
    data = event.data
    case event
    when OrgGraph::Events::PersonRecorded
      { job_title: data[:title], manager_id: data[:manager_id], status: STATUS.fetch(data[:employment_status]) }
    when OrgGraph::Events::TitleChanged then { job_title: data[:title] }
    when OrgGraph::Events::ManagerChanged then { manager_id: data[:manager_id] }
    when OrgGraph::Events::PersonLeft then { status: "inactive" }
    when OrgGraph::Events::PersonJoined, OrgGraph::Events::PersonReturned then { status: "active" }
    end
  end
end
