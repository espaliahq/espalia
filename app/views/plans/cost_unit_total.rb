# frozen_string_literal: true

# A unit's cost beside its name: what its own places cost in the scenario,
# and the difference from Today over the same days.
class Views::Plans::CostUnitTotal < Views::Base
  Format = Views::Plans::CostMarks::Format

  # @param row [Hash] a unit from `team_planning_cost`
  # @param reference [String, nil] the reference currency
  def initialize(row:, reference:)
    @row = row
    @reference = reference
  end

  def view_template
    return if [ @row[:scenario], @row[:baseline] ].all? { it[:native].empty? }

    span(data: { cost_unit: @row[:unit_id] }, class: "flex flex-wrap items-baseline gap-x-1 text-sm tabular-nums") do
      span(class: "sr-only") { "Cost:" }
      span(class: "font-medium text-default") { Format.sum(@row[:scenario], @reference) }
      change = Format.sum_change(@row[:difference], @reference)
      span(class: "text-muted") { "(#{change} vs Today)" } if change
    end
  end
end
