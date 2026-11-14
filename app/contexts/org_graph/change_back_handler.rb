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
    entries.uniq(&:event_id).each { authorize_inverse!(it) }
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
    when "UnitMoved" then authorize_move_unit!(entry.unit_id, entry.before["parent_id"])
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
      entries.uniq(&:event_id).each do |entry|
        options = { effective_on: (effective_on || entry.effective_on).to_s, changed_back_id: entry.event_id }
        send(:"undo_#{entry.event_type.underscore}", entry, options)
        ensure_inverted!(entry)
      end
    end
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

    entries.each do |entry|
      raise "#{entry.event_type.titleize} can't be changed back" unless entry.reversible?
      raise "This change has already been changed back" if entry.changed_back?
      raise "#{entry.provider} supplies this; change it there" unless (entry.provider || ESPALIA) == ESPALIA
    end
    unless entries.all? { |entry| entry.latest?(apart_from:) }
      raise "A later change has replaced this one; change that back first"
    end
    return unless entries.any? { |entry| moved_start_earlier?(entry) }

    raise "This moved the day they joined earlier, which can't be undone yet"
  end

  # A set dated before the membership it changed gave that membership an
  # earlier start. No command withdraws those days
  # ([#154](https://github.com/espaliahq/espalia/issues/154)), so its inverse
  # would only set the same terms on the same day again.
  def moved_start_earlier?(entry)
    entry.event_type == "MembershipSet" && entry.before && terms_known_before(entry).nil?
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

  def undo_unit_owner_added(entry, options)
    @structure.remove_unit_owner(entry.unit_id, entry.person_id, **options)
  end

  def undo_unit_owner_removed(entry, options)
    @structure.add_unit_owner(entry.unit_id, entry.person_id, **options)
  end
end
