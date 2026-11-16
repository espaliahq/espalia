# frozen_string_literal: true

# The quiet line under a scenario's cost: what its seats cost a year on its
# last day, against Today's seats priced that same day
# ([#334](https://github.com/espaliahq/espalia/issues/334)). One sentence that
# wraps, so a narrow strip or table cell never widens.
class Views::Plans::RunRateAtEnd < Views::Base
  Format = Views::Plans::CostMarks::Format

  # @param run_rate [Hash, nil] `run_rate_at_end` from a cost read; nil draws nothing
  # @param reference [String, nil] the reference currency
  def initialize(run_rate:, reference:)
    @run_rate = run_rate
    @reference = reference
  end

  def view_template
    return unless @run_rate

    total = @run_rate[:total]
    change = Format.sum_change(total[:difference], @reference)
    span(data: { run_rate_at_end: "" }, class: "block basis-full text-xs tabular-nums text-muted") do
      "Run rate on #{Date.iso8601(@run_rate[:on]).strftime('%-d %b %Y')}: #{Format.yearly(Format.sum(total[:scenario], @reference))}, " \
        "#{change ? "#{change} on Today's" : "same as Today's"}"
    end
  end
end
