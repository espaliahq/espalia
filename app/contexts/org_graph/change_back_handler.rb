# frozen_string_literal: true

# "Change it back": undoes one entry of a unit's activity by issuing its
# inverse as a new event. History keeps both; nothing is deleted.
#
# The inverse goes through the ordinary handlers, under the same actor, so it
# is refused wherever the change itself would be. It is also refused for an
# entry another provider supplied, for one already changed back, and for one
# a later change to the same fact has overtaken, in any unit it touched.
#
# The inverse takes effect when the original did, unless the caller names
# another date, so the fact reads as if the change never happened.
#
class OrgGraph::ChangeBackHandler
  ESPALIA = OrgGraph::StructureAggregate::ESPALIA

  # @param actor [AuthorizationContext, Object] as for {OrgGraph::CommandHandler}
  # @param repository [OrgGraph::Repository]
  def initialize(actor:, repository: OrgGraph::Repository.new)
    @people = OrgGraph::CommandHandler.new(actor:, repository:)
    @structure = OrgGraph::StructureCommandHandler.new(actor:, repository:)
  end

  # @param entry [OrgUnitActivity] the entry to change back
  # @param effective_on [Date, String, nil] when the inverse takes effect;
  #   the original's effective date when nil
  # @raise [RuntimeError] if the entry can't be changed back
  # @raise [OrgGraph::Authorization::Refused] if the actor can't make the inverse change
  def change_back(entry, effective_on: nil)
    ActiveRecord::Base.transaction do
      entry = lock(entry)
      ensure_reversible!(entry)
      options = { effective_on: (effective_on || entry.effective_on).to_s, changed_back_id: entry.event_id }
      send(:"undo_#{entry.event_type.underscore}", entry, options)
      ensure_inverted!(entry)
    end
  end

  private

  # Locks every unit's row for the change, so a second request waits and
  # then sees the first one's inverse.
  def lock(entry)
    OrgUnitActivity.where(event_id: entry.event_id).order(:id).lock.to_a.find { |row| row.id == entry.id }
  end

  # Rolls back an inverse the aggregate turned into something else, or skipped
  # because the fact already reads as it did before.
  def ensure_inverted!(entry)
    types = OrgUnitActivity.where(changes_back_id: entry.event_id).distinct.pluck(:event_type)
    raise "Nothing to change back; it already reads as it did before" if types.empty?
    return unless entry.event_type == "MembershipMoved" && types != [ "MembershipMoved" ]

    raise "This person can't move back: they have left, or are already in that unit"
  end

  def ensure_reversible!(entry)
    raise "#{entry.event_type.titleize} can't be changed back" unless entry.reversible?
    raise "This change has already been changed back" if entry.changed_back?
    raise "#{entry.provider} supplies this; change it there" unless (entry.provider || ESPALIA) == ESPALIA
    raise "A later change has replaced this one; change that back first" unless every_unit_latest?(entry)
  end

  def every_unit_latest?(entry)
    OrgUnitActivity.where(event_id: entry.event_id).all?(&:latest?)
  end

  def undo_membership_set(entry, options)
    return undo_membership_ended(entry, options) if entry.before

    @people.end_membership(entry.person_id, entry.unit_id, provider: ESPALIA, **options)
  end

  def undo_membership_ended(entry, options)
    terms = entry.before.to_h.symbolize_keys.slice(:allocation, :role)
    @people.set_membership(entry.person_id, entry.unit_id, **terms, provider: ESPALIA, **options)
  end

  def undo_membership_moved(entry, options)
    from, to = entry.after ? [ entry.other_unit_id, entry.unit_id ] : [ entry.unit_id, entry.other_unit_id ]
    @people.move_membership(entry.person_id, to, from, **options)
  end

  def undo_unit_renamed(entry, options)
    @structure.rename_unit(entry.unit_id, entry.before["name"], **options)
  end

  def undo_unit_moved(entry, options)
    @structure.move_unit(entry.unit_id, entry.before["parent_id"], **options)
  end

  def undo_unit_owner_added(entry, options)
    @structure.remove_unit_owner(entry.unit_id, entry.person_id, **options)
  end

  def undo_unit_owner_removed(entry, options)
    @structure.add_unit_owner(entry.unit_id, entry.person_id, **options)
  end
end
