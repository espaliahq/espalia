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

  # The day a member leaves a retiring unit: the retirement's, or the day
  # their membership began or last changed, if later.
  #
  # @param membership [OrgMembership]
  # @param on [Date, String] the retirement date
  # @param repository [OrgGraph::Repository]
  # @return [Date]
  def self.leaving_on(membership, on:, repository:)
    changed_on = repository.load_person(membership.person_id).membership_changed_on(membership.unit_id)
    [ Date.iso8601(on.to_s), membership.member_since, changed_on ].compact.max
  end

  # Refuses, and so rolls the retirement back, while the member list is
  # rebuilt: it reads the members from that list.
  #
  # @param event [OrgGraph::Events::UnitRetired]
  # @raise [ProjectionVersion::Rebuilding]
  def call(event)
    ActsAsTenant.with_tenant(Tenant.find(event.metadata[:tenant_id])) do
      ProjectionVersion.unless_rebuilding(OrgGraph::Projections::Members::PROJECTION_NAME) { handle(event.data) }
    end
  end

  private

  def handle(data)
    successor_ids = Array(data[:successor_ids])
    successor_id = successor_ids.first if successor_ids.one?
    commands = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    repository = OrgGraph::Repository.new

    OrgMembership.where(unit_id: data[:unit_id]).to_a.each do |membership|
      effective_on = self.class.leaving_on(membership, on: data[:effective_on], repository:)
      options = { effective_on: effective_on, **data.slice(:plan_id, :plan_change_id) }

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
