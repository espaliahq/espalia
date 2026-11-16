# frozen_string_literal: true

# The quiet line under a cost or capacity total: what is actual, planned and
# forecast in it ([#352](https://github.com/espaliahq/espalia/issues/352)).
# It wraps part by part, so a narrow card or table cell never widens.
class Views::Plans::FigureParts < Views::Base
  # @param parts [Array<Array(String, String)>] each label and its figure, as drawn
  def initialize(parts:)
    @parts = parts
  end

  def view_template
    return if @parts.empty?

    span(data: { figure_parts: "" }, class: "flex basis-full flex-wrap items-baseline gap-x-2 text-xs tabular-nums text-muted") do
      @parts.each_with_index do |(label, figure), index|
        span(class: "inline-flex items-baseline gap-x-2") do
          span(aria: { hidden: true }) { "·" } if index.positive?
          span(data: { part: label.downcase }) { "#{label} #{figure}" }
        end
      end
    end
  end
end
