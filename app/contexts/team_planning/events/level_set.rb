# frozen_string_literal: true

# A planned promotion: the level a scenario has someone at. The level is the
# plan's statement about that person, so it seals under their key in the
# plan, and forgetting them makes it unreadable.
#
# A level the Org Graph cleared is followed as no level, stored as {CLEARED}
# so it seals like any other and reads as removed once they are forgotten.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :subject_id the person's id
#   @option data [Shreddable::Value] :level {CLEARED} for no level
#   Plus {TeamPlanning::Events::Change::FIELDS}.
#
class TeamPlanning::Events::LevelSet < TeamPlanning::Events::Change
  extend Shreddable
  extend TeamPlanning::Events::SealedChange

  shreddable :level, by: :person, person: :subject_id
  about_a_person

  CLEARED = ""

  # @return [String]
  def self.facet = "level"

  # @param end_state [Hash] `{ level: }`, the level nil or {CLEARED} for no level
  # @return [Hash] `{ level: }`, no level as {CLEARED}
  # @raise [TeamPlanning::Error] without the level key
  def self.end_state(end_state)
    raise TeamPlanning::Error, "A planned level names the level" unless end_state.key?(:level)

    { level: end_state[:level].to_s.strip }
  end

  # Whether a planned level says no level. One whose key is gone says nothing anyone can read.
  #
  # @param level [Shreddable::Value, String, nil]
  # @return [Boolean]
  def self.cleared?(level)
    return false if level.nil? || (level.is_a?(Shreddable::Value) && level.removed?)

    (level.is_a?(Shreddable::Value) ? level.reveal : level) == CLEARED
  end

  # A cleared level compares as no level, as the Org Graph reads one.
  #
  # @param left [Hash, nil]
  # @param right [Hash, nil]
  # @return [Boolean]
  def self.same_end_state?(left, right) = super(as_read(left), as_read(right))

  def self.as_read(end_state)
    end_state && cleared?(end_state.to_h.transform_keys(&:to_sym)[:level]) ? { level: nil } : end_state
  end
  private_class_method :as_read

  # @param map [TeamPlanning::Baseline::Map]
  # @param data [Hash]
  # @return [TeamPlanning::Baseline::Map]
  def self.apply_to(map, data) = on_person(map, data) { it.with(planned_level: data[:level]) }

  # Off the plan's map, the planned level; off today's, the Org Graph's.
  #
  # @param map [TeamPlanning::Baseline::Map]
  # @param subject_id [String]
  # @param facet [String]
  # @return [Hash, nil]
  def self.read_from(map, subject_id:, facet: self.facet)
    person = map.people.find { it.id == subject_id } or return nil
    return { level: nil } if cleared?(person.planned_level)

    { level: person.planned_level || person.level }
  end

  # @param change [OrgGraph::ChangesBetween::Change]
  # @return [String, nil] the person, when the Org Graph changes their level
  def self.subject_moved_by(change) = (change.person_id if change.kind == :fact_changed && change.fact == "level")
end
