# frozen_string_literal: true

# The hero's state panel: an inset whose edge and heading take the verdict's
# hue. The vocabulary settings preview renders it too, so the two can't drift.
#
# @example
#   render Views::Assessments::VerdictPanel.new(state: :mastering) do |panel|
#     panel.heading("Mastering E3 · 62% of the way to E4")
#   end
class Views::Assessments::VerdictPanel < Views::Base
  EDGES = {
    underperforming: "border-verdict-below",
    progressing: "border-verdict-progressing",
    performing: "border-verdict-performing",
    top_of_ladder: "border-verdict-performing",
    eligible: "border-verdict-eligible",
    mastering: "border-verdict-mastering"
  }.freeze

  ACCENTS = {
    underperforming: "text-verdict-below",
    progressing: "text-verdict-progressing",
    performing: "text-verdict-performing",
    top_of_ladder: "text-verdict-performing",
    eligible: "text-verdict-eligible",
    mastering: "text-verdict-mastering"
  }.freeze

  # @param state [Symbol, nil] a `performance_state`; anything else draws a neutral panel
  # @param attributes [Hash] extra attributes for the panel
  def initialize(state:, **attributes)
    @state = state
    @attributes = attributes
  end

  def view_template
    render Components::Kit::Card.new(variant: :inset, density: :compact, edge: EDGES[@state], **@attributes) do |card|
      card.body { yield self }
    end
  end

  # The state's headline, in the verdict's hue.
  #
  # @param text [String]
  def heading(text)
    span(class: "min-w-0 text-xs font-semibold uppercase tracking-wide #{ACCENTS.fetch(@state, 'text-muted')}") do
      text
    end
  end
end
