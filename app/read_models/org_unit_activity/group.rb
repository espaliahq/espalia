# frozen_string_literal: true

# The entries of one unit's activity written under one cause, such as the
# moves, endings and succession of one approved split, read as one change.
#
# Built by {OrgUnitActivity.feed}. An entry alone in its cause is a group of one.
#
class OrgUnitActivity::Group
  MEMBERSHIP_PHRASES = {
    moved_in: "moved %s in", moved_out: "moved %s out", added: "added %s",
    changed: "changed the terms of %s", removed: "removed %s"
  }.freeze
  private_constant :MEMBERSHIP_PHRASES

  # @return [Array<OrgUnitActivity>] newest first
  attr_reader :parts

  # @param parts [Array<OrgUnitActivity>] newest first, sharing one cause
  def initialize(parts)
    @parts = parts
  end

  # @return [String]
  def cause_id = latest.cause_id

  # @return [OrgUnitActivity]
  def latest = parts.first

  # @return [ActiveSupport::TimeWithZone]
  def learned_at = latest.learned_at

  # @return [String, nil]
  def plan_id = parts.filter_map(&:plan_id).first

  # @return [String, nil]
  def plan_change_id = parts.filter_map(&:plan_change_id).first

  # @return [Boolean]
  def changed_back? = parts.all?(&:changed_back?)

  # What the group did, in a sentence: "split Payments into Billing and
  # Ledger", or "moved 10 people out and removed 2 people".
  #
  # @return [String]
  def summary
    succession = parts.find { |part| part.event_type == "UnitSucceeded" }
    return succession_summary(succession.after) if succession

    (membership_phrases + unit_phrases).to_sentence
  end

  private

  def succession_summary(after)
    names = unit_names(after.values_at("predecessor_ids", "successor_ids").flatten)
    predecessors, successors = after.values_at("predecessor_ids", "successor_ids").map do |ids|
      ids.map { |id| names.fetch(id, "an unnamed unit") }.sort.to_sentence
    end
    case [ after["predecessor_ids"].one?, after["successor_ids"].one? ]
    when [ true, true ] then "replaced #{predecessors} with #{successors}"
    when [ true, false ] then "split #{predecessors} into #{successors}"
    when [ false, true ] then "merged #{predecessors} into #{successors}"
    else "reorganised #{predecessors} into #{successors}"
    end
  end

  def unit_names(ids) = OrgUnit.where(id: ids).pluck(:id, :name).to_h

  def membership_phrases
    counts = parts.filter_map { |part| membership_change(part) }.tally
    MEMBERSHIP_PHRASES.filter_map do |change, phrase|
      count = counts[change] or next
      format(phrase, "#{count} #{'person'.pluralize(count)}")
    end
  end

  def membership_change(part)
    case part.event_type
    when "MembershipMoved" then part.after ? :moved_in : :moved_out
    when "MembershipSet" then part.before ? :changed : :added
    when "MembershipEnded" then :removed
    end
  end

  def unit_phrases
    types = parts.map(&:event_type).tally
    [
      ("created the unit" if types["UnitCreated"]),
      renamed_phrase,
      ("moved the unit" if types["UnitMoved"]),
      owners_phrase("added", types["UnitOwnerAdded"]),
      owners_phrase("removed", types["UnitOwnerRemoved"]),
      ("retired the unit" if types["UnitRetired"])
    ].compact
  end

  def renamed_phrase
    renames = parts.select { |part| part.event_type == "UnitRenamed" }
    return if renames.empty?

    "renamed it from #{renames.last.before['name']} to #{renames.first.after['name']}"
  end

  def owners_phrase(verb, count)
    "#{verb} #{count} #{'owner'.pluralize(count)}" if count
  end
end
