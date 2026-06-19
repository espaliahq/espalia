# frozen_string_literal: true

# Renders a pending behavioural-expectation creation suggestion as a ghost in an
# otherwise-empty matrix cell, so a proposed expectation is visible in the grid
# (not just the activity feed). The amber wavy underline is the explorer's
# established "pending change" signal (same as inline diffs and the pending
# illustration ghost) — no separate label needed. Approve/reject happens via the
# activity feed (the entry is actionable); amend/withdraw via the suggestion page.
class Views::Frameworks::Explorer::PendingExpectationFrame < Views::Base
  include Views::Frameworks::Explorer::Concerns::SuggestionDecoration

  # @param suggestion [FrameworkState::SuggestedEdit] kind: "create", target: behavioural_expectation
  def initialize(suggestion:)
    @suggestion = suggestion
    @attrs = (suggestion.proposed_attributes || {}).symbolize_keys
  end

  def view_template
    p(class: "mb-1 text-sm #{suggestion_text_classes(pending_edit_count: 1)}") { proposed_text }
  end

  private

  # An amended create carries its current value in suggested_value (the amend
  # only updates that field); fall back to the original proposed description.
  def proposed_text
    @suggestion.suggested_value.presence || @attrs[:description]
  end
end
