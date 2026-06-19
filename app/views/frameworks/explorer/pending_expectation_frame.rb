# frozen_string_literal: true

# Renders a pending behavioural-expectation creation suggestion as a ghost in an
# otherwise-empty matrix cell, so a proposed expectation is visible in the grid
# (not just the activity feed). Amber wavy decoration signals its tentative
# status; approve/reject happens via the activity feed (the entry is actionable)
# and amend/withdraw via the suggestion page.
class Views::Frameworks::Explorer::PendingExpectationFrame < Views::Base
  include Views::Frameworks::Explorer::Concerns::SuggestionDecoration

  # @param suggestion [FrameworkState::SuggestedEdit] kind: "create", target: behavioural_expectation
  def initialize(suggestion:)
    @suggestion = suggestion
    @attrs = (suggestion.proposed_attributes || {}).symbolize_keys
  end

  def view_template
    div(class: "mb-1") do
      span(class: "inline-block text-[10px] font-semibold uppercase tracking-wide " \
                  "text-amber-700 dark:text-amber-300") { "Proposed" }
      p(class: "text-sm #{suggestion_text_classes(pending_edit_count: 1)}") { @attrs[:description] }
    end
  end
end
