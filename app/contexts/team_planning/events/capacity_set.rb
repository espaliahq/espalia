# frozen_string_literal: true

# A planner's figure for what someone delivers in one place, in place of the
# one their capacity model works out. The figure is the plan's judgement
# about that person, so it and its note seal under their key in the plan, and
# forgetting them leaves the place priced as unknown, never as the model would
# price it.
#
# Each place is its own facet, so clearing one override keeps the others.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :subject_id the person's id
#   @option data [String, nil] :position_id the place, when it is a position
#   @option data [String, nil] :unit_id the place, when it is straight in a unit
#   @option data [Shreddable::Value] :amount a decimal string, 0 or more
#   Plus {TeamPlanning::Events::Change::FIELDS}.
#
class TeamPlanning::Events::CapacitySet < TeamPlanning::Events::Change
  extend Shreddable
  extend TeamPlanning::Events::SealedChange

  shreddable :amount, by: :person, person: :subject_id
  about_a_person

  PLACES = TeamPlanning::Events::AssignmentSet::PLACES
  PLACE_ID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  # @return [String]
  def self.facet = "capacity"

  # @param data [Hash]
  # @return [Array<String>] the place the amount is for
  def self.refers_to(data) = data.values_at(:position_id, :unit_id).compact

  # @param end_state [Hash] `{ position_id or unit_id, amount }`
  # @return [Hash] the place downcased, the amount a decimal string
  # @raise [TeamPlanning::Error] for a place in both a position and a unit, or neither, or an amount
  #   that isn't a number of 0 or more
  def self.end_state(end_state)
    places = PLACES.to_h { [ it, end_state[it].to_s.strip.downcase.presence ] }
    raise TeamPlanning::Error, "An override is for a position or a unit, not both" if places.values.all?
    raise TeamPlanning::Error, "An override names the position or unit it is for" if places.values.none?

    { **places, amount: amount!(end_state[:amount]) }
  end

  # @param data [Hash]
  # @return [String, nil] the position or unit the override is for
  def self.place_of(data) = data[:position_id] || data[:unit_id]

  # @param map [TeamPlanning::Baseline::Map]
  # @param data [Hash]
  # @return [TeamPlanning::Baseline::Map]
  def self.apply_to(map, data)
    on_person(map, data) { it.with(capacity_overrides: it.capacity_overrides.merge(place_of(data) => data[:amount])) }
  end

  # @param facet [String]
  # @return [Boolean]
  def self.holds?(facet) = facet.start_with?("#{self.facet}:") && facet.delete_prefix("#{self.facet}:").match?(PLACE_ID)

  def self.amount!(value)
    amount = value.to_s.strip
    raise TeamPlanning::Error, "An override is a number of units, 0 or more" unless amount.match?(/\A\d+(\.\d+)?\z/)

    amount
  end

  private_class_method :amount!

  # @return [Array(String, String)]
  def key = [ data[:subject_id], "#{self.class.facet}:#{self.class.place_of(data)}" ]
end
