# frozen_string_literal: true

# "Change it back": undoes one entry of a unit's activity, or every entry of
# one cause, by issuing the inverses as new events. History keeps both;
# nothing is deleted.
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
  include OrgGraph::Authorization

  ESPALIA = OrgGraph::StructureAggregate::ESPALIA
  WHOLE_STRUCTURE = "This came with a change to a unit's own structure, so change the whole change back"
  WHOLE_MOVE = "This came with a move between structures, so change the whole change back"
  GRANT = "Who may edit the Org Graph changes in its settings, not here"

  # @param actor [AuthorizationContext, Object] as for {OrgGraph::CommandHandler}
  # @param repository [OrgGraph::Repository]
  def initialize(actor:, repository: OrgGraph::Repository.new)
    @actor = actor!(actor)
    @repository = repository
  end

  # @param entry [OrgUnitActivity] the entry to change back
  # @param effective_on [Date, String, nil] when the inverse takes effect;
  #   the original's effective date when nil
  # @raise [RuntimeError] if the entry can't be changed back
  # @raise [OrgGraph::Authorization::Refused] if the actor can't make the inverse change
  def change_back(entry, effective_on: nil)
    reverse(effective_on:) { OrgUnitActivity.where(event_id: entry.event_id).order(position: :desc) }
  end

  # Changes back every entry written under one cause, such as one approved
  # plan change, newest first, under one new cause. Refused as a whole unless
  # every part can be changed back; a later change from inside the same cause
  # doesn't count against an earlier part, as it is reversed first. The inverses
  # share the request's cause, or a new one outside a request.
  #
  # @param cause_id [String] as {OrgUnitActivity::Group#cause_id}
  # @param effective_on [Date, String, nil] as for {#change_back}
  # @raise [RuntimeError] if any part can't be changed back
  # @raise [OrgGraph::Authorization::Refused] if the actor can't make every inverse change
  def change_back_group(cause_id, effective_on: nil)
    inverse_cause = AuditMetadata.current[:correlation_id] || SecureRandom.uuid_v7
    reverse(effective_on:, apart_from: cause_id, inverse_cause:) { OrgUnitActivity.caused_by(cause_id) }
  end

  # Why {#change_back} would refuse the entry, read without taking a lock or
  # writing, so a screen offers the button only where it would work. A refusal
  # that depends on the write itself, such as a person who has since left,
  # still surfaces only from {#change_back}.
  #
  # @param entry [OrgUnitActivity]
  # @return [String, nil] the reason, or nil when it can be changed back
  def refusal(entry)
    refusal_for(OrgUnitActivity.where(event_id: entry.event_id).to_a)
  end

  # As {#refusal}, for {#change_back_group}.
  #
  # @param cause_id [String]
  # @return [String, nil]
  def group_refusal(cause_id)
    refusal_for(OrgUnitActivity.caused_by(cause_id).to_a, apart_from: cause_id)
  end

  private

  def refusal_for(entries, apart_from: nil)
    ensure_reversible!(entries, apart_from:)
    inverted(entries).each { authorize_inverse!(it) }
    nil
  rescue Refused, RuntimeError => e
    e.message
  end

  # The check the handler behind each undo_* makes.
  def authorize_inverse!(entry)
    case entry.event_type
    when "MembershipSet", "MembershipEnded" then authorize_membership!(entry.person_id, entry.unit_id)
    when "MembershipMoved"
      from, to = entry.after ? [ entry.unit_id, entry.other_unit_id ] : [ entry.other_unit_id, entry.unit_id ]
      authorize_move_membership!(entry.person_id, from, to)
    when "UnitMoved"
      authorize_move_unit!(entry.unit_id, entry.before["parent_id"])
      authorize_move_back_across!(entry) if across?(entry)
    when "UnitKindChanged" then authorize_unit_kind!(entry.unit_id)
    when "TaxonomyDefined" then authorize_structure_of!(entry.unit_id)
    else authorize_unit!(entry.unit_id)
    end
  end

  def reverse(effective_on:, apart_from: nil, inverse_cause: nil, &rows)
    ActiveRecord::Base.transaction do
      held = lock(rows.call)
      entries = rows.call.to_a
      raise "This change is still being written; try again in a moment" unless streams(entries) <= held
      ensure_reversible!(entries, apart_from:)
      build_handlers(cause_id: inverse_cause)
      inverted(entries).each do |entry|
        options = { effective_on: (effective_on || entry.effective_on).to_s, changed_back_id: entry.event_id }
        next undo_structure(entry, options, entries) if entry.subject == "structure"
        next undo_move_across(entry, options, entries) if across?(entry)

        send(:"undo_#{entry.event_type.underscore}", entry, options)
      end
      entries.uniq(&:event_id).each { ensure_inverted!(it) }
    end
  end

  # The entries whose inverse is issued directly: a structure's own or a move
  # between structures, which sends the units it retyped back as well, or
  # else each one.
  def inverted(entries)
    structure = entries.select { it.subject == "structure" }
    structure.presence || entries.select { across?(it) }.uniq(&:event_id).presence || entries.uniq(&:event_id)
  end

  def across?(entry) = entry.event_type == "UnitMoved" && entry.after.to_h.key?("conversion")

  # The rights the move back needs on the structure it leaves and the one it
  # joins, read without the lock; the write checks them again under it.
  def authorize_move_back_across!(entry)
    structure = (@loaded_structure ||= @repository.load_structure)
    authorize_move_across!(structure.structure_left_by(entry.unit_id), structure.structure_joined_beneath(entry.before["parent_id"]))
  end

  def build_handlers(cause_id:)
    @people = OrgGraph::CommandHandler.new(actor: @actor, cause_id:, repository: @repository)
    @structure = OrgGraph::StructureCommandHandler.new(actor: @actor, cause_id:, repository: @repository)
  end

  # Takes the stream locks every ordinary write to these facts takes, the
  # structure's before any person's, so no change can land between the checks
  # and the inverses. The caller reads the entries afresh once they are held.
  def lock(entries)
    structure, person_ids = streams(entries).partition { |stream| stream == :structure }
    @repository.lock_structure if structure.any?
    person_ids.sort.each { |person_id| @repository.lock_person(person_id) }
    streams(entries)
  end

  def streams(entries)
    entries.to_set { |entry| entry.subject.to_s.start_with?("membership:") ? entry.person_id : :structure }
  end

  # Rolls back an inverse the aggregate turned into something else, or skipped
  # because the fact already reads as it did before.
  def ensure_inverted!(entry)
    types = OrgUnitActivity.where(changes_back_id: entry.event_id).distinct.pluck(:event_type)
    raise "Nothing to change back; it already reads as it did before" if types.empty?
    return unless entry.event_type == "MembershipMoved" && types != [ "MembershipMoved" ]

    raise "This person can't move back: they have left, or are already in that unit"
  end

  def ensure_reversible!(entries, apart_from:)
    raise "Nothing to change back" if entries.empty?
    if apart_from && entries.any?(&:changed_back?)
      raise "Part of this change has already been changed back; change the rest back one entry at a time"
    end

    causes = OrgUnitActivity.where(cause_id: entries.map(&:cause_id))
    structure_causes = causes.where(subject: "structure").distinct.pluck(:cause_id)
    move_causes = causes.where(event_type: "UnitMoved").where("after ? 'conversion'").distinct.pluck(:cause_id)
    structure = entries.find { it.subject == "structure" }
    move = entries.find { across?(it) }
    ensure_structure_reversible!(structure, entries, apart_from:) if structure
    ensure_move_reversible!(move, entries, apart_from:) if move && !structure

    entries.each do |entry|
      raise whole_structure_refusal(entry.cause_id) if !structure && structure_causes.include?(entry.cause_id)
      raise whole_refusal(entry.cause_id, WHOLE_MOVE) if !move && move_causes.include?(entry.cause_id)
      raise GRANT if entry.grant?
      raise "#{entry.event_type.titleize} can't be changed back" unless entry == structure || entry.reversible?
      raise "This change has already been changed back" if entry.changed_back?
      raise "#{entry.provider} supplies this; change it there" unless (entry.provider || ESPALIA) == ESPALIA
    end
    unless entries.all? { |entry| entry.latest?(apart_from:) }
      raise "A later change has replaced this one; change that back first"
    end
    return unless entries.any? { |entry| moved_start_earlier?(entry) }

    raise "This moved the day they joined earlier, which can't be undone yet"
  end

  # A unit's own structure changes back whole: its declaration or withdrawal
  # with every unit it retyped, as one change.
  def ensure_structure_reversible!(structure, entries, apart_from:)
    raise whole_structure_refusal(structure.cause_id) unless apart_from
    unless entries.all? { it == structure || it.event_type == "UnitKindChanged" }
      raise "This came with a change to a unit's own structure, which can't be changed back yet"
    end
    return unless structure.before && structure.after

    raise "A change to a structure's unit types can't be changed back yet"
  end

  # A move between structures changes back whole: the move with every unit
  # it retyped, as one change. A type change its conversion didn't make came
  # with it in the same request, and changing it back would need its own
  # inverse. A change back's conversion can be empty, as each unit took back
  # its own type, so its type changes count when they undo the reversed move's.
  def ensure_move_reversible!(move, entries, apart_from:)
    raise whole_refusal(move.cause_id, WHOLE_MOVE) unless apart_from

    conversion = Rails.configuration.event_store.read.event(move.event_id).data[:conversion].to_h.transform_keys(&:to_s)
    restored = restored_kind_ids(move)
    carried = lambda do |kind|
      kind.event_type == "UnitKindChanged" &&
        (conversion[kind.before&.dig("level_id").to_s] == kind.after&.dig("level_id") || restored.include?(kind.changes_back_id))
    end
    return if entries.all? { it.event_id == move.event_id || carried.(it) }

    raise "This came with a move between structures, which can't be changed back yet"
  end

  def restored_kind_ids(move)
    return [] unless move.changes_back_id

    reversed = OrgUnitActivity.find_by(event_id: move.changes_back_id)
    reversed ? OrgUnitActivity.where(cause_id: reversed.cause_id, event_type: "UnitKindChanged").pluck(:event_id) : []
  end

  # Sends the caller to the whole change, unless that is refused too.
  def whole_structure_refusal(cause_id) = whole_refusal(cause_id, WHOLE_STRUCTURE)

  def whole_refusal(cause_id, refusal) = refusal_for(OrgUnitActivity.caused_by(cause_id).to_a, apart_from: cause_id) || refusal

  # A set dated before the membership it changed gave that membership an
  # earlier start. No command withdraws those days
  # ([#154](https://github.com/espaliahq/espalia/issues/154)), so its inverse
  # would only set the same terms on the same day again.
  def moved_start_earlier?(entry)
    entry.event_type == "MembershipSet" && entry.before && terms_known_before(entry).nil?
  end

  # A declaration is withdrawn, and a withdrawal declared again with the same
  # type ids; either way each unit goes back to the type its own entry says it
  # held, which inverting the conversion can't tell once two types became one.
  def undo_structure(entry, options, entries)
    kinds = entries.select { it.event_type == "UnitKindChanged" }.to_h do |kind|
      [ kind.unit_id, { level_id: kind.before["level_id"], changed_back_id: kind.event_id } ]
    end
    return @structure.change_declaration_back(entry.unit_id, kinds:, **options) if entry.after

    levels = Rails.configuration.event_store.read.event(entry.event_id).data[:previous_levels]
    @structure.change_withdrawal_back(entry.unit_id, levels:, kinds:, **options)
  end

  # Each unit that moved goes back to the type its own entry says it held.
  def undo_move_across(entry, options, entries)
    kinds = entries.select { it.event_type == "UnitKindChanged" }.to_h do |kind|
      [ kind.unit_id, { level_id: kind.before["level_id"], changed_back_id: kind.event_id } ]
    end
    @structure.change_move_back(entry.unit_id, entry.before["parent_id"], kinds:, **options)
  end

  def undo_membership_set(entry, options)
    return @people.end_membership(entry.person_id, entry.unit_id, provider: ESPALIA, **options) unless entry.before

    terms = terms_known_before(entry).symbolize_keys.slice(:allocation, :role)
    @people.set_membership(entry.person_id, entry.unit_id, **terms, provider: ESPALIA, **options)
  end

  # The terms in effect on the entry's day as the history knew them just before
  # it. The entry's `before` is the change learned before it, which a backdated
  # change sits ahead of. Every membership period is learned from the person's
  # stream, so its earlier events say exactly what was known; timestamps can tie.
  def terms_known_before(entry)
    earlier = Rails.configuration.event_store.read.stream(EventStreamNaming.person_stream(entry.person_id))
                   .to(entry.event_id).map(&:event_id)
    periods = membership_periods(entry).in_effect_on(entry.effective_on).where(learned_by_event_id: earlier)
    periods.where(superseded_by_event_id: nil).or(periods.where.not(superseded_by_event_id: earlier)).pick(:value)
  end

  def membership_periods(entry)
    OrgFactPeriod.where(subject_type: OrgGraph::Projections::History::PERSON, subject_id: entry.person_id,
                        fact: "membership", key: entry.unit_id)
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

  def undo_unit_kind_changed(entry, options)
    @structure.change_unit_kind(entry.unit_id, entry.before["level_id"], **options)
  end

  def undo_unit_owner_added(entry, options)
    @structure.remove_unit_owner(entry.unit_id, entry.person_id, **options)
  end

  def undo_unit_owner_removed(entry, options)
    @structure.add_unit_owner(entry.unit_id, entry.person_id, **options)
  end
end
