# frozen_string_literal: true

# A planned promotion: the level a scenario has someone at. The level is the
# plan's statement about that person, so it seals under their key in the
# plan, and forgetting them makes it unreadable.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :subject_id the person's id
#   @option data [Shreddable::Value] :level
#   Plus {TeamPlanning::Events::Change::FIELDS}.
#
class TeamPlanning::Events::LevelSet < TeamPlanning::Events::Change
  extend Shreddable
  extend TeamPlanning::Events::SealedChange

  shreddable :level, by: :person, person: :subject_id

  # @return [String]
  def self.facet = "level"

  # @param end_state [Hash] `{ level: }`
  # @return [Hash]
  # @raise [TeamPlanning::Error] without a level
  def self.end_state(end_state)
    level = end_state[:level].to_s.strip.presence or raise TeamPlanning::Error, "A planned level names the level"

    { level: }
  end

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

    { level: person.planned_level || person.level }
  end

  # @param change [OrgGraph::ChangesBetween::Change]
  # @return [String, nil] the person, when the Org Graph changes their level
  def self.subject_moved_by(change) = (change.person_id if change.kind == :fact_changed && change.fact == "level")
end
