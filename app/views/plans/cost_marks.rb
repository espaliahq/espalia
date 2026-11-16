# frozen_string_literal: true

# One scenario's cost on the map, from `team_planning_cost`
# ([#316](https://github.com/espaliahq/espalia/issues/316)): the figures the
# strip and each unit card draw, against Today over the same days. Today's
# own map shows its yearly run rate, which stands alone
# ([#318](https://github.com/espaliahq/espalia/issues/318)).
class Views::Plans::CostMarks
  # How money reads on the plan's pages. The read sends exact decimal
  # strings; only this rounds.
  module Format
    module_function

    # @param figure [String, BigDecimal]
    # @param currency [String]
    # @return [String] to three significant figures, such as "EUR 3.21m", "EUR 148k" or "EUR 950"
    def amount(figure, currency)
      value = BigDecimal(figure.to_s)
      "#{'-' if value.round.negative?}#{currency} #{short(value.abs)}"
    end

    # @return [String, nil] such as "+EUR 148k", nil when the difference rounds to nothing
    def change(figure, currency)
      value = BigDecimal(figure.to_s)
      return nil if value.abs < BigDecimal("0.5")

      "#{value.positive? ? '+' : '-'}#{currency} #{short(value.abs)}"
    end

    # @param sum [Hash] `{ native:, converted:, missing: }` from a cost read
    # @param reference [String, nil] the reference currency
    # @return [String] the converted figure, else each currency's
    def sum(sum, reference)
      return amount(sum[:converted], reference) if sum[:converted]
      return "nothing" if sum[:native].empty?

      sum[:native].map { |currency, figure| amount(figure, currency) }.join(" + ")
    end

    # @return [String, nil] "+EUR 148k", "same as Today" or the natives' changes; nil when nothing changes in any currency
    def sum_change(sum, reference)
      return change(sum[:converted], reference) if sum[:converted]

      changes = sum[:native].filter_map { |currency, figure| change(figure, currency) }
      changes.join(", ").presence
    end

    def short(value)
      return "#{significant(value / 1_000_000)}m" if value >= 999_500
      return "#{significant(value / 1000)}k" if value >= 999.5

      value.round.to_i.to_s
    end

    # @param parts [Hash] `{ actual:, planned:, forecast: }`, each a sum
    # @param reference [String, nil] the reference currency
    # @return [Array<Array(String, String)>] each part's label and figure
    def parts(parts, reference)
      forecast = sum_change(parts[:forecast], reference)
      [ [ "Actual", sum(parts[:actual], reference) ],
        [ "Planned", sum_change(parts[:planned], reference) || no_change(parts, reference) ],
        ([ "Forecast", forecast ] if forecast) ].compact
    end

    def no_change(parts, reference)
      currencies = reference ? [ reference ] : parts.values.flat_map { it[:native].keys }.uniq
      currencies.one? ? amount(0, currencies.first) : "nothing"
    end

    # @return [String] such as "EUR 1.2m a year"
    def yearly(text) = "#{text} a year"

    def significant(value) = ActiveSupport::NumberHelper.number_to_rounded(value, precision: 3, significant: true, strip_insignificant_zeros: true)
  end

  attr_reader :cost

  # @param cost [Hash] from `team_planning_cost`, without a unit's working
  # @param map [Hash] from `team_planning_scenario_map`, for the open positions' names
  def initialize(cost:, map:)
    @cost = cost
    @map = map
  end

  # @return [Boolean] whether any band prices anything in the scenario or Today
  def priced? = total.values_at(:scenario, :baseline).compact.any? { it[:native].any? }

  # @return [Boolean] whether this is Today's yearly run rate, never compared with anything
  def run_rate? = @cost[:basis] == "run_rate"

  # @return [Hash] `{ scenario:, baseline:, difference: }`, each a sum; only `scenario` for a run rate
  def total = @cost[:total]

  # @return [String, nil]
  def reference = @cost[:reference_currency]

  # @return [Hash, nil] the scenario's figures in no unit, nil when there are none
  def outside_units
    row = @cost[:units].find { it[:unit_id].nil? }
    row if row && row[:scenario][:native].any?
  end

  # @return [Array<Hash>] seats left out, each `{ name:, reason: }`
  def unpriced
    @cost[:unpriced].map { { name: seat_name(it), reason: it[:reason_text] } }
  end

  # @return [#call] the map's `unit_marks` hook
  def unit_marks
    rows = @cost[:units].index_by { it[:unit_id] }
    ->(unit) { (row = rows[unit[:id]]) ? [ Views::Plans::CostUnitTotal.new(row:, reference:, run_rate: run_rate?) ] : [] }
  end

  private

  def seat_name(seat)
    return @cost[:names].fetch(seat[:seat_id], "Someone") if seat[:kind] == "person"

    position_names.fetch(seat[:seat_id], "An open position")
  end

  def position_names
    @position_names ||= @map[:positions].group_by { it[:unit_id] }.values.map { Views::Plans::ScenarioMap.position_names(it) }.reduce({}, :merge)
  end
end
