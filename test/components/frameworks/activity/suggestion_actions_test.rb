# frozen_string_literal: true

require "test_helper"

# The §12 inline action row. Pins the instant-feedback contract: the visible
# Approve/Reject cluster and the hidden resolved marker the suggestion-action
# controller swaps between, keyed by the suggestion id it listens for on
# window `suggestion:resolved` events.
class Views::Frameworks::Activity::SuggestionActionsTest < ActiveSupport::TestCase
  # Through a real view context — the component builds the approve route.
  # @return [String] the rendered HTML
  def render_actions(suggestion_id: SecureRandom.uuid_v7)
    view_context.render(Views::Frameworks::Activity::SuggestionActions.new(
      framework_id: SecureRandom.uuid_v7, suggestion_id: suggestion_id,
      entity_label: "capability description", reject_preview: "Sharper text"
    ))
  end

  # @return [ActionView::Base] a request-backed view context for rendering
  def view_context
    @view_context ||= ApplicationController.new
      .tap { |controller| controller.request = ActionDispatch::TestRequest.create }
      .view_context
  end

  context "Views::Frameworks::Activity::SuggestionActions" do
    should "render the action cluster and a hidden resolved marker" do
      sid = SecureRandom.uuid_v7
      html = render_actions(suggestion_id: sid)

      assert_includes html, 'data-suggestion-action-target="actions"'
      assert_match(/<p[^>]*class="hidden[^>]*data-suggestion-action-target="resolved"/, html)
      assert_includes html, %(data-suggestion-action-suggestion-id-value="#{sid}")
      assert_includes html, "suggestion:resolved@window->suggestion-action#onResolved"
    end
  end
end
