# frozen_string_literal: true

# One unit per full-time equivalent, whatever the role or level: the
# simplest model.
class TeamPlanning::CapacityModels::PerFte < TeamPlanning::CapacityModel
  # @return [String]
  def self.model_name = "per_fte"

  # @return [String]
  def self.description = "One unit per full-time equivalent, whatever the role or level"

  # @return [String]
  def self.symbol = "FTE"

  # @param params [Hash] none
  # @return [Hash]
  # @raise [TeamPlanning::Error] for any parameter
  def self.check(params)
    raise TeamPlanning::Error, "per_fte takes no params, not #{params.keys.join(", ")}" if params.any?

    params
  end

  # @param seat [TeamPlanning::CapacityModel::Seat]
  # @param place [TeamPlanning::CapacityModel::Place]
  # @return [TeamPlanning::CapacityModel::Figure]
  def self.capacity_of(seat, place:, params:, map:, facts: Facts.new)
    amount = seat.fte * place.allocation
    Figure.new(amount:, working: [
      Step.new(label: seat.fte_known ? "FTE" : "FTE not recorded, counted as 1", amount: seat.fte, op: "+"),
      Step.new(label: place.allocation_known ? "Share of the seat in this place" : "Share not recorded, split from what the other places leave",
               amount: place.allocation, op: "×"),
      Step.new(label: "Units, at 1 per FTE", amount:, op: "=")
    ])
  end
end
