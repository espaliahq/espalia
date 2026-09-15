# frozen_string_literal: true

# Shared nudge for the per-framework `framework_activity` Turbo stream —
# replaces the hidden sync-signal element that `context_pane_controller`
# observes to reload the context pane (feed or suggestion card), AND the
# header's "N pending" badge, which sits outside the pane's frame.
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
    broadcast_pending_count_badge(framework_id)
  rescue => e
    # A broadcast failure must never break the projection's write path.
    Rails.logger.warn("[#{self.class.name}] Activity broadcast failed: #{e.message}")
  end

  # A published version closes the draft, so every open explorer must drop
  # the `vN draft` pill and the Publish button — both sit outside every Turbo
  # Frame. Rendered hidden (`visible: false`) so the replacement is the same
  # empty anchor for every viewer regardless of their rights or of a draft
  # re-opened in the meantime; whoever published, the header stops lying.
  #
  # @param framework_id [String, nil] no-op when nil
  def broadcast_draft_status_cleared(framework_id)
    return if Projections::Replayer.replay_mode?
    return unless framework_id

    framework = FrameworkState::Framework.find_by(framework_id: framework_id)
    return unless framework

    { badge: Views::Frameworks::Explorer::DraftStatus::BADGE_ID,
      publish: Views::Frameworks::Explorer::DraftStatus::PUBLISH_ID }.each do |slot, target|
      Turbo::StreamsChannel.broadcast_replace_to(
        "framework_activity", framework_id,
        target: target,
        html: ApplicationController.render(
          Views::Frameworks::Explorer::DraftStatus.new(framework: framework, slot: slot, visible: false),
          layout: false
        )
      )
    end
  rescue => e
    Rails.logger.warn("[#{self.class.name}] Draft status broadcast failed: #{e.message}")
  end

  # The header badge lives OUTSIDE the context pane's Turbo Frame, so the pane's
  # reload could never update it — it kept its page-load value until a full
  # reload (a suggestion landed, the feed showed it, the badge still said 6).
  # Riding the same broadcast is what makes header and pane agree within one
  # broadcast rather than one page load.
  #
  # Counts pending *proposals* only: an open clarification is a discussion, not
  # a pending change, matching FrameworksController's page-load count.
  def broadcast_pending_count_badge(framework_id)
    count = FrameworkState::SuggestedEdit
      .where(framework_id: framework_id).pending.proposals.count

    Turbo::StreamsChannel.broadcast_replace_to(
      "framework_activity", framework_id,
      target: Views::Frameworks::Explorer::PendingCountBadge::BADGE_ID,
      html: ApplicationController.render(
        Views::Frameworks::Explorer::PendingCountBadge.new(count: count), layout: false
      )
    )
  end
end
