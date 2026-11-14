# frozen_string_literal: true

# Synchronous projection of each unit's current members, from the person
# streams.
#
# Writes `org_memberships`, and nothing else writes it. A membership's row
# goes when it ends; its history stays in the person's stream. A membership
# set with an earlier date than the row's can move `member_since` back but
# keeps the later terms, as history does.
#
class OrgGraph::Projections::Members
  # Stable identifier used as the natural key in `projection_versions.name`.
  PROJECTION_NAME = "org_graph/members"

  # Bump when `reset!` or any handler would write different state from the
  # same event payload than before.
  CODE_VERSION = 2

  # @return [Array<Class>]
  def self.handled_events
    [ OrgGraph::Events::MembershipSet, OrgGraph::Events::MembershipEnded, OrgGraph::Events::MembershipMoved ]
  end

  # Truncates every read model this projection writes, scoped to one tenant.
  #
  # @param tenant [Tenant]
  def self.reset!(tenant:)
    ActsAsTenant.with_tenant(tenant) { OrgMembership.where(tenant_id: tenant.id).delete_all }
  end

  # @param event [RubyEventStore::Event]
  def call(event)
    ActsAsTenant.with_tenant(Tenant.find(event.metadata[:tenant_id])) do
      case event
      when OrgGraph::Events::MembershipSet then handle_membership_set(event.data)
      when OrgGraph::Events::MembershipEnded then OrgMembership.where(event.data.slice(:person_id, :unit_id)).delete_all
      when OrgGraph::Events::MembershipMoved then handle_membership_moved(event.data)
      end
    end
  end

  private

  def handle_membership_moved(data)
    from = OrgMembership.find_by(person_id: data[:person_id], unit_id: data[:from_unit_id])
    member_since = from&.member_since || data[:effective_on]
    from&.delete
    OrgMembership.find_or_initialize_by(data.slice(:person_id, :unit_id))
                 .update!(**data.slice(:allocation, :role, :provider, :effective_on), member_since: member_since)
  end

  def handle_membership_set(data)
    membership = OrgMembership.find_or_initialize_by(data.slice(:person_id, :unit_id))
    effective_on = Date.iso8601(data[:effective_on])
    membership.member_since = [ membership.member_since, effective_on ].compact.min
    return membership.save! if membership.effective_on && membership.effective_on > effective_on

    membership.update!(data.slice(:allocation, :role, :provider, :effective_on))
  end
end
