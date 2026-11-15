# frozen_string_literal: true

# A scenario's cost in the Scenarios table, from `team_planning_scenario_costs`:
# its total over its own period and the difference from Today over the same days.
class Views::Plans::CostCell < Views::Base
  Format = Views::Plans::CostMarks::Format

  # @param row [Hash, nil] the scenario's row; nil for Today
  # @param reference [String, nil] the reference currency
  def initialize(row:, reference:)
    @row = row
    @reference = reference
  end

  def view_template
    return span(class: "text-sm text-muted") { "No period of its own" } unless @row
    return span(class: "text-sm text-muted", title: @row[:error]) { "Can't be priced" } if @row[:error]

    total = @row[:total]
    span(data: { cost_cell: @row[:scenario_id] }, class: "flex flex-wrap items-baseline gap-x-1 text-sm tabular-nums") do
      span(class: "font-medium text-default") { Format.sum(total[:scenario], @reference) }
      change = Format.sum_change(total[:difference], @reference)
      span(class: "text-muted") { change ? "(#{change} vs Today)" : "(same as Today)" }
      span(class: "text-muted") { "#{@row[:unpriced]} left out" } if @row[:unpriced].positive?
    end
  end
end
