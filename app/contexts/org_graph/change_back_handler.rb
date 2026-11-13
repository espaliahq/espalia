# frozen_string_literal: true

# "Change it back": undoes one entry of a unit's activity by issuing its
# inverse as a new event. History keeps both; nothing is deleted.
#
# The inverse goes through the ordinary handlers, under the same actor, so it
# is refused wherever the change itself would be. It is also refused for an
# entry another provider supplied, for one already changed back, and for one
# a later change to the same fact has overtaken, in any unit it touched.
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
  # @param effective_on [Date, String] when the inverse takes effect
  # @raise [RuntimeError] if the entry can't be changed back
  # @raise [OrgGraph::Authorization::Refused] if the actor can't make the inverse change
  def change_back(entry, effective_on: Date.current)
    ensure_reversible!(entry)
    options = { effective_on: effective_on.to_s, changed_back_id: entry.event_id }
    send(:"undo_#{entry.event_type.underscore}", entry, options)
  end

  private

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
    if entry.before
      @people.set_membership(entry.person_id, entry.unit_id, **terms(entry.before), provider: ESPALIA, **options)
    else
      @people.end_membership(entry.person_id, entry.unit_id, provider: ESPALIA, **options)
    end
  end

  def undo_membership_ended(entry, options)
    @people.set_membership(entry.person_id, entry.unit_id, **terms(entry.before), provider: ESPALIA, **options)
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

  def terms(values) = values.to_h.symbolize_keys.slice(:allocation, :role)
end
