# frozen_string_literal: true

# Synchronous projection of each unit's current members, from the person
# streams.
#
# Writes `org_memberships`, and nothing else writes it. A membership's row
# goes when it ends; its history stays in the person's stream. The rows follow
# {OrgGraph::MembershipFold}, as the person aggregate does: a set dated earlier
# than the row's moves `member_since` back and keeps the later terms. A
# change-back refolds the person from their stream, since one that withdraws a
# change can bring back terms the rows no longer hold.
#
class OrgGraph::Projections::Members
  # Stable identifier used as the natural key in `projection_versions.name`.
  PROJECTION_NAME = "org_graph/members"

  # Bump when `reset!` or any handler would write different state from the
  # same event payload than before.
  CODE_VERSION = 3

  # @return [Array<Class>]
  def self.handled_events = OrgGraph::MembershipFold::EVENTS

  # Truncates every read model this projection writes, scoped to one tenant.
  #
  # @param tenant [Tenant]
  def self.reset!(tenant:)
    ActsAsTenant.with_tenant(tenant) { OrgMembership.where(tenant_id: tenant.id).delete_all }
  end

  # @param event [RubyEventStore::Event]
  def call(event)
    ActsAsTenant.with_tenant(Tenant.find(event.metadata[:tenant_id])) do
      person_id = event.data[:person_id]
      rows = OrgMembership.where(person_id:)
      write(rows, fold(event, rows).memberships)
    end
  end

  private

  def fold(event, rows)
    return OrgGraph::MembershipFold.through(event) if event.data[:changed_back_id].present?

    held = rows.to_h do |row|
      [ row.unit_id, { allocation: row.allocation, role: row.role, provider: row.provider,
                       since: row.member_since.to_s, changed_on: row.effective_on.to_s } ]
    end
    OrgGraph::MembershipFold.new(held).tap { it.apply(event) }
  end

  def write(rows, memberships)
    rows.where.not(unit_id: memberships.keys).delete_all
    memberships.each do |unit_id, membership|
      rows.find_or_initialize_by(unit_id:).update!(**membership.slice(:allocation, :role, :provider),
        member_since: membership[:since], effective_on: membership[:changed_on])
    end
  end
end
