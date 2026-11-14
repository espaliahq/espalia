# frozen_string_literal: true

# A unit's capacity beside its name: each model's total, and its change
# from Today on any other scenario.
class Views::Plans::CapacityUnitTotal < Views::Base
  Format = Views::Plans::CapacityMarks::Format

  # @param totals [Array<Views::Plans::CapacityMarks::Total>]
  # @param baseline [Boolean] whether the map shows Today, so there is no change to show
  # @param empty [String, nil] what to say when there are no totals; nil draws nothing
  def initialize(totals:, baseline:, empty: nil)
    @totals = totals
    @baseline = baseline
    @empty = empty
  end

  def view_template
    return span(class: "text-sm text-muted") { @empty } if @totals.empty? && @empty
    return if @totals.empty?

    span(data: { capacity_unit: "" }, class: "flex flex-wrap items-baseline gap-x-2 text-sm tabular-nums") do
      span(class: "sr-only") { "Capacity:" }
      @totals.each do |total|
        span(data: { capacity_total: total.model }) do
          span(class: "font-medium text-default") { Format.amount(total.amount, total.unit) }
          change = Format.change(total.change, total.unit) unless @baseline
          span(class: "ml-1 text-muted") { "(#{change} vs Today)" } if change
        end
      end
    end
  end
end
