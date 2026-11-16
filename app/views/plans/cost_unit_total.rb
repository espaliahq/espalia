# frozen_string_literal: true

# A unit's cost beside its name: what its own places cost in the scenario,
# and the difference from Today over the same days. On Today's map, its
# yearly run rate alone.
class Views::Plans::CostUnitTotal < Views::Base
  Format = Views::Plans::CostMarks::Format

  # @param row [Hash] a unit from `team_planning_cost`
  # @param reference [String, nil] the reference currency
  # @param run_rate [Boolean] whether the row is Today's yearly run rate
  def initialize(row:, reference:, run_rate: false)
    @row = row
    @reference = reference
    @run_rate = run_rate
  end

  def view_template
    return if [ @row[:scenario], @row[:baseline] ].compact.all? { it[:native].empty? }

    span(data: { cost_unit: @row[:unit_id] }, class: "flex flex-wrap items-baseline gap-x-1 text-sm tabular-nums") do
      span(class: "sr-only") { "Cost:" }
      figure = Format.sum(@row[:scenario], @reference)
      span(class: "font-medium text-default") { @run_rate ? Format.yearly(figure) : figure }
      change = Format.sum_change(@row[:difference], @reference) if @row[:difference]
      span(class: "text-muted") { "(#{change} vs Today)" } if change
      render Views::Plans::FigureParts.new(parts: Format.parts(@row[:parts], @reference)) unless @run_rate
    end
  end
end
