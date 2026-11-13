# frozen_string_literal: true

# Cross-stream synchronous handler: when a unit retires, closes each open
# membership in it, in the member's own stream.
#
# - A plain retirement, or a split (several successors), ends each membership
#   on the retirement date. Whoever issued a split has already moved the
#   people they named, so those left are the ones nobody placed. They land in
#   the "in no team" tray; the handler never guesses a successor.
# - A retirement through a succession with one successor (a merge or a
#   replacement) moves each membership to it, so nobody is ended and added
#   again. A member who has left is ended instead.
#
# RES stamps every event published here with the retirement as its
# causation_id, so each change carries the retirement as its cause.
#
# A membership that began or changed after the retirement date closes on the
# day of that change, since none can close before its last change. The date
# comes from the member's stream: the projection keeps the latest event's
# date, which a backdated change moves earlier.
#
# NEVER replayed on projection rebuild: it dispatches person commands. It is
# subscribed, not registered in `Projections::Registry::REPLAYABLE`.
#
class OrgGraph::SyncHandlers::RetiredUnitMemberships
  # @return [Array<Class>]
  def self.handled_events
    [ OrgGraph::Events::UnitRetired ]
  end

  # @param event [OrgGraph::Events::UnitRetired]
  def call(event)
    ActsAsTenant.with_tenant(Tenant.find(event.metadata[:tenant_id])) { handle(event.data) }
  end

  private

  def handle(data)
    successor_ids = Array(data[:successor_ids])
    successor_id = successor_ids.first if successor_ids.one?
    commands = OrgGraph::CommandHandler.new
    repository = OrgGraph::Repository.new

    OrgMembership.where(unit_id: data[:unit_id]).to_a.each do |membership|
      changed_on = repository.load_person(membership.person_id).membership_changed_on(data[:unit_id])
      effective_on = [ Date.iso8601(data[:effective_on]), membership.member_since, changed_on ].compact.max
      options = { effective_on: effective_on, plan_change_id: data[:plan_change_id] }

      if successor_id
        commands.move_membership(membership.person_id, data[:unit_id], successor_id,
                                 moved_by_id: data[:retired_by_id], **options)
      else
        commands.end_membership(membership.person_id, data[:unit_id], provider: membership.provider,
                                                                      ended_by_id: data[:retired_by_id], **options)
      end
    end
  end
end
