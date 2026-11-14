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
#     def self.capacity_of(seat, place:, params:, map:, facts:)
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
  # @!attribute op [String, nil] "+" adds to the figure, "×" scales it, "=" is the result
  # @!attribute subject_id [String, nil] the person or position the step is about, such as a report
  Step = Data.define(:label, :amount, :op, :subject_id) do
    def initialize(op: nil, subject_id: nil, **) = super
  end

  # @!attribute amount [Rational]
  # @!attribute working [Array<Step>] how the model reached the amount
  # @!attribute overloaded [Boolean] the seat costs more to run than it delivers, so the amount is floored
  # @!attribute excess [Rational] by how much, when overloaded, for the whole seat: before its share and FTE
  # @!attribute notes [Array<String>] what a reader should know about the seat, as keys a screen can name
  # @!attribute reason [String, nil] why the model can't price the place, so it counts nowhere
  Figure = Data.define(:amount, :working, :overloaded, :excess, :notes, :reason) do
    def initialize(overloaded: false, excess: 0r, notes: [], reason: nil, **) = super
  end

  # What the query resolved, which a model can't read off the map alone.
  #
  # @!attribute level_of [Hash{String => Integer}] person or position id => level ordinal, where one resolves
  # @!attribute ordinal_of [Hash{String => Integer}] level id => ordinal
  # @!attribute role_ids_of [Hash{String => Array<String>}] person or position id => the roles its places do
  # @!attribute open_fte [Hash{String => Rational}] position id => the FTE its occupants leave open
  # @!attribute cache [Hash] for a model to keep what it works out once per map
  Facts = Data.define(:level_of, :ordinal_of, :role_ids_of, :open_fte, :cache) do
    def initialize(level_of: {}, ordinal_of: {}, role_ids_of: {}, open_fte: {}, cache: {}) = super
  end

  # @return [String] the name a rule chooses the model by, in snake_case
  def self.model_name = raise(NotImplementedError, "#{name} must name its model")

  # @return [String] what the model counts, for the tools that list models
  def self.description = raise(NotImplementedError, "#{name} must describe its model")

  # @return [String] what follows a figure on screen, such as "u"
  def self.symbol = model_name

  # @param params [Hash] with string keys
  # @return [Hash] the parameters as stored
  # @raise [TeamPlanning::Error] naming what is wrong, never a value
  def self.check(params) = params

  # @return [Hash{String => String}] what each of the model's {Figure#notes} keys says
  def self.notes = {}

  # A seat in two places may be priced by two models, so a model prices one
  # place, its allocation included.
  #
  # @param seat [Seat]
  # @param place [Place] one of the seat's places
  # @param params [Hash] as {.check} stored them
  # @param map [TeamPlanning::Baseline::Map] the resolved scenario
  # @param facts [Facts]
  # @return [Figure]
  def self.capacity_of(seat, place:, params:, map:, facts: Facts.new) = raise(NotImplementedError, "#{name} must say how it prices a seat")
end
