# frozen_string_literal: true

# What a scenario's forecast assumptions add to it, as rows per unit and step
# ([#351](https://github.com/espaliahq/espalia/issues/351)). Computed when
# read and never stored, so a row has no id, person or position: nothing can
# pin, clear, undo, note or approve it, and the change list never holds one.
#
# A step is the scenario's period, the unit cost and the timeline use. Today
# has no period, so it forecasts nothing: it is all actual.
#
# @example
#   TeamPlanning::Forecast.new(aggregate:, scenario_id:, map:).rows # => [Row, ...]
class TeamPlanning::Forecast
  # One assumption's addition to one unit in one step.
  #
  # @!attribute kind [String] the rule that forecast it
  # @!attribute unit_id [String, nil] nil for no unit
  # @!attribute cost_centre [String, nil] nil for no cost centre
  # @!attribute starts_on [Date]
  # @!attribute ends_on [Date]
  # @!attribute headcount [Rational] people added, or taken away when negative
  # @!attribute cost [Hash{String => Rational}] currency => amount over the step
  # @!attribute capacity [Hash{String => Rational}] capacity model => amount
  Row = Data.define(:kind, :unit_id, :cost_centre, :starts_on, :ends_on, :headcount, :cost, :capacity)

  # What a kind reads to forecast one step.
  #
  # @!attribute kind [Class<TeamPlanning::ForecastKind>]
  # @!attribute map [TeamPlanning::Baseline::Map] the scenario's resolved map
  # @!attribute step [Range<Date>]
  # @!attribute covered [Set<String>] subjects a planned change in the scenario's chain sets
  Frame = Data.define(:kind, :map, :step, :covered) do
    # @param subject_id [String] a person, position or unit
    # @return [Boolean] whether a planned change already says what happens to it
    def covered?(subject_id) = covered.include?(subject_id)

    # @param unit_id [String, nil]
    # @return [Hash] the kind's rule as it resolves at that unit
    def rule_at(unit_id) = map.rule(kind.rule_name, unit_id:)

    # @return [Row] a row of this kind for this step
    def row(unit_id:, cost_centre: nil, headcount: 0r, cost: {}, capacity: {})
      Row.new(kind: kind.rule_name, unit_id:, cost_centre:, starts_on: step.begin, ends_on: step.end, headcount:, cost:, capacity:)
    end
  end

  # @param aggregate [TeamPlanning::PlanAggregate]
  # @param scenario_id [String] a scenario, or the plan's id for Today
  # @param map [TeamPlanning::Baseline::Map] the scenario's resolved map
  def initialize(aggregate:, scenario_id:, map:)
    @aggregate = aggregate
    @scenario_id = scenario_id
    @map = map
  end

  # @return [Array<Row>] every forecast kind's rows, by kind, unit and step
  # @raise [TeamPlanning::Error] for a scenario the plan doesn't have
  def rows
    step = @aggregate.period_of(@scenario_id) or return []

    covered = @aggregate.resolution_chain(@scenario_id).flat_map { @aggregate.changes_in(it) }.to_set { it.data[:subject_id] }
    TeamPlanning::RuleKinds.forecasts.flat_map do |kind|
      kind.forecast(Frame.new(kind:, map: @map, step:, covered:)).each do |row|
        raise ArgumentError, "#{kind} forecast something other than a row" unless row.is_a?(Row)
      end
    end
  end
end
