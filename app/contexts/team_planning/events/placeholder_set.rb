# frozen_string_literal: true

# A hire the plan adds before the HRIS knows them: a label, and the level and
# FTE they'd join at. A placeholder is not a person, so all three seal under
# the plan's key and forgetting anyone leaves it as it was. It's placed like
# anyone else, with an {AssignmentSet}.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :subject_id an id the plan minted
#   @option data [Shreddable::Value] :label
#   @option data [Shreddable::Value, nil] :level
#   @option data [Shreddable::Value, nil] :fte
#   Plus {TeamPlanning::Events::Change::FIELDS}.
#
class TeamPlanning::Events::PlaceholderSet < TeamPlanning::Events::Change
  extend Shreddable
  extend TeamPlanning::Events::SealedChange

  shreddable :label, :level, :fte, by: :plan

  # @return [String]
  def self.facet = "placeholder"

  # @return [Boolean]
  def self.creates_subject? = true

  # @param end_state [Hash] `{ label:, level:, fte: }`, level and FTE optional
  # @return [Hash]
  # @raise [TeamPlanning::Error] without a label, or with an FTE out of range
  def self.end_state(end_state)
    label = end_state[:label].to_s.strip.presence or raise TeamPlanning::Error, "A placeholder hire has a label"
    fte = end_state[:fte].nil? ? nil : TeamPlanning::Events::PlanDataSet.fte!(end_state[:fte])

    { label:, level: end_state[:level].to_s.strip.presence, fte: }
  end

  # Resolution lands every placeholder first, so editing one never lands it
  # after what places it.
  #
  # @param map [TeamPlanning::Baseline::Map]
  # @param data [Hash]
  # @return [TeamPlanning::Baseline::Map]
  def self.apply_to(map, data)
    plan_data = data.slice(:level, :fte).compact
    existing = map.people.find { it.id == data[:subject_id] }
    hire = (existing || TeamPlanning::Baseline::Member.placeholder(data[:subject_id], data[:label]))
           .with(placeholder: data[:label], plan_data:)
    map.with(people: existing ? map.people.map { it.id == hire.id ? hire : it } : map.people + [ hire ])
  end

  # @param map [TeamPlanning::Baseline::Map]
  # @param subject_id [String]
  # @param facet [String]
  # @return [Hash, nil]
  def self.read_from(map, subject_id:, facet: self.facet)
    hire = map.people.find { it.id == subject_id && it.placeholder? } or return nil

    { label: hire.placeholder, level: hire.plan_data[:level], fte: hire.plan_data[:fte] }
  end
end
