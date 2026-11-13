# frozen_string_literal: true

# Synchronous projection of who has left and when, from the person streams.
#
# Writes `org_leavers`, and nothing else writes it. The leaving date is the
# latest `PersonLeft`'s, so a corrected date replaces the first. For a person
# the provider stopped returning, that is the day the sync noticed. A person
# first recorded as a leaver with no date left on the day they were recorded.
# A person forgotten drops off, so they are never due twice.
#
class OrgGraph::Projections::Leavers
  # Stable identifier used as the natural key in `projection_versions.name`.
  PROJECTION_NAME = "org_graph/leavers"

  # Bump when `reset!` or any handler would write different state from the
  # same event payload than before.
  CODE_VERSION = 1

  # @return [Array<Class>]
  def self.handled_events
    [ OrgGraph::Events::PersonRecorded, OrgGraph::Events::PersonLeft, OrgGraph::Events::PersonReturned,
      OrgGraph::Events::PersonForgotten ]
  end

  # Truncates every read model this projection writes, scoped to one tenant.
  #
  # @param tenant [Tenant]
  def self.reset!(tenant:)
    ActsAsTenant.with_tenant(tenant) { OrgLeaver.where(tenant_id: tenant.id).delete_all }
  end

  # @param event [RubyEventStore::Event]
  def call(event)
    ActsAsTenant.with_tenant(Tenant.find(event.metadata[:tenant_id])) do
      data = event.data
      case event
      when OrgGraph::Events::PersonRecorded
        left(data, data[:left_on] || data[:effective_on]) if data[:employment_status] == "left"
      when OrgGraph::Events::PersonLeft then left(data, data[:effective_on])
      when OrgGraph::Events::PersonReturned, OrgGraph::Events::PersonForgotten then dropped(data)
      end
    end
  end

  private

  def left(data, left_on)
    OrgLeaver.find_or_initialize_by(person_id: data[:person_id]).update!(left_on: left_on)
  end

  def dropped(data)
    OrgLeaver.where(person_id: data[:person_id]).delete_all
  end
end
