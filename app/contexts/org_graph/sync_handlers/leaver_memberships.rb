# frozen_string_literal: true

# Cross-stream synchronous handler: when a person leaves, ends each of their
# open memberships on the leaving date, as the system. A returner comes back
# with none, and no position is opened in their place.
#
# A membership that began or changed after the leaving date ends on the day
# of that change, since none can end before its last change. A second
# `PersonLeft` that corrects the date finds nothing open, so memberships keep
# the date they ended on.
#
# RES stamps each event published here with the leaving as its causation_id,
# and the leaving's correlation id carries through, so a sync or a plan
# approval reads as one change. The ends share the leaving's transaction.
#
# NEVER replayed on projection rebuild: it dispatches person commands. It is
# subscribed, not registered in `Projections::Registry::REPLAYABLE`.
#
class OrgGraph::SyncHandlers::LeaverMemberships
  # @return [Array<Class>]
  def self.handled_events
    [ OrgGraph::Events::PersonLeft ]
  end

  # @param event [OrgGraph::Events::PersonLeft]
  def call(event)
    ActsAsTenant.with_tenant(Tenant.find(event.metadata[:tenant_id])) { handle(event.data) }
  end

  private

  def handle(data)
    commands = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    repository = OrgGraph::Repository.new

    OrgMembership.where(person_id: data[:person_id]).to_a.each do |membership|
      effective_on = OrgGraph::SyncHandlers::RetiredUnitMemberships.leaving_on(membership, on: data[:effective_on], repository:)
      commands.end_membership(membership.person_id, membership.unit_id, provider: membership.provider,
                                                                        effective_on:, **data.slice(:plan_id, :plan_change_id))
    end
  end
end
