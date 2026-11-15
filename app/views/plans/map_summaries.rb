# frozen_string_literal: true

# The strips above the map, one under another: cost, then capacity.
class Views::Plans::MapSummaries < Views::Base
  # @param summaries [Array<Phlex::SGML>]
  def initialize(summaries)
    @summaries = summaries
  end

  def view_template
    div(class: "space-y-3") { @summaries.each { render it } }
  end
end
