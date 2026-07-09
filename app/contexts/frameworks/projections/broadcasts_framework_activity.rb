# frozen_string_literal: true

# Shared nudge for the per-framework `framework_activity` Turbo stream —
# replaces the hidden sync-signal element that `context_pane_controller`
# observes to reload the context pane (feed or suggestion card).
#
# One home for the signal markup: the element id and data attributes are a
# byte-level contract with the pane's MutationObserver, so the projections
# that broadcast (PublishedState for framework events, SuggestionThread for
# comment events) must emit identical markup or live reload silently dies
# for one family of events.
#
module Frameworks::Projections::BroadcastsFrameworkActivity
  private

  # @param framework_id [String, nil] no-op when nil (unresolvable target)
  def broadcast_framework_activity_signal(framework_id)
    return if Projections::Replayer.replay_mode?
    return unless framework_id

    Turbo::StreamsChannel.broadcast_replace_to(
      "framework_activity", framework_id,
      target: "framework-activity-sync-signal",
      html: '<div id="framework-activity-sync-signal" class="hidden" ' \
            "data-context-pane-target=\"signal\" data-updated-at=\"#{Time.current.to_f}\"></div>"
    )
  rescue => e
    # A broadcast failure must never break the projection's write path.
    Rails.logger.warn("[#{self.class.name}] Activity broadcast failed: #{e.message}")
  end
end
