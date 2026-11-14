# frozen_string_literal: true

# One way of counting what a seat can deliver, such as units on a curve by
# level or plain fractions of a person. A role family names the model it uses
# in the `capacity_model` rule ({TeamPlanning::RuleKinds::Capacity}), and a
# role can name another.
#
# A model prices a seat, filled or vacant alike, so empty seats can't flatter
# a scenario. It sees the whole resolved map, so a model can read the
# reporting graph around the seat. Figures stay exact: a model returns
# Rationals, and only a display rounds them.
#
# Parameters may be close to pay, so a refusal from {.check} names what is
# wrong and never repeats a value.
#
# @example
#   class TeamPlanning::CapacityModels::Fractions < TeamPlanning::CapacityModel
#     def self.model_name = "fractions"
#     def self.description = "A person's share of their time"
#     def self.capacity_of(seat, place:, params:, map:)
#       amount = seat.fte * place.allocation
#       Figure.new(amount:, working: [ Step.new(label: "FTE × allocation", amount:) ])
#     end
#   end
class TeamPlanning::CapacityModel
  # A person, or an open position, where capacity is counted.
  #
  # A position's seat is what its occupants leave open, so a position is
  # never counted twice. A model finds the reporting lines around a seat on
  # the map, by its id.
  #
  # @!attribute id [String] the person's or the position's id
  # @!attribute kind [String] "person" or "position"
  # @!attribute fte [Rational] a position's open FTE
  # @!attribute fte_known [Boolean] false when the person has no FTE recorded and counts as one
  # @!attribute places [Array<Place>]
  Seat = Data.define(:id, :kind, :fte, :fte_known, :places)

  # Where a seat does its work, and as what. A position's role and level hold
  # for whoever fills it; a person placed straight in a unit takes their own.
  #
  # @!attribute unit_id [String, nil] nil for a person in no unit
  # @!attribute allocation [Rational] the share of the seat this place holds
  # @!attribute allocation_known [Boolean] false when the HRIS gave none, and the place shares what the seat's other places leave
  # @!attribute role_id [String]
  # @!attribute level_id [String, nil] nil when the level resolves to none
  # @!attribute position_id [String, nil] the position whose work this is, if any
  Place = Data.define(:unit_id, :allocation, :allocation_known, :role_id, :level_id, :position_id)

  # @!attribute label [String] what the step counts, for a person's card
  # @!attribute amount [Rational]
  Step = Data.define(:label, :amount)

  # @!attribute amount [Rational]
  # @!attribute working [Array<Step>] how the model reached the amount
  Figure = Data.define(:amount, :working)

  # @return [String] the name a rule chooses the model by, in snake_case
  def self.model_name = raise(NotImplementedError, "#{name} must name its model")

  # @return [String] what the model counts, for the tools that list models
  def self.description = raise(NotImplementedError, "#{name} must describe its model")

  # @param params [Hash] with string keys
  # @return [Hash] the parameters as stored
  # @raise [TeamPlanning::Error] naming what is wrong, never a value
  def self.check(params) = params

  # A seat in two places may be priced by two models, so a model prices one
  # place, its allocation included.
  #
  # @param seat [Seat]
  # @param place [Place] one of the seat's places
  # @param params [Hash] as {.check} stored them
  # @param map [TeamPlanning::Baseline::Map] the resolved scenario
  # @return [Figure]
  def self.capacity_of(seat, place:, params:, map:) = raise(NotImplementedError, "#{name} must say how it prices a seat")
end
