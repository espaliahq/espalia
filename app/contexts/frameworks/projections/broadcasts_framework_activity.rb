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
    broadcast_draft_status(framework_id, visible: false)
  end

  # The mirror of {#broadcast_draft_status_cleared}. A draft opens from many
  # writes that answer only their own frame — a binding edit, the levels
  # editor, an approval, any MCP call — and every other viewer's explorer is
  # stale too, so announcing it from the event is the one place that reaches
  # them all.
  #
  # @param framework_id [String, nil] no-op when nil
  def broadcast_draft_status_opened(framework_id)
    broadcast_draft_status(framework_id, visible: true)
  end

  # Both slots, sent once the write commits: a draft announced from inside a
  # transaction that then rolls back would offer a Publish button for a draft
  # that never existed. The badge rides the activity stream every edit-mode
  # viewer holds. The Publish slot rides the publishers stream for opens AND
  # clears, because ActionCable doesn't order messages across subscriptions — a
  # clear on one stream could land after the next draft's button on the other.
  def broadcast_draft_status(framework_id, visible:)
    return if Projections::Replayer.replay_mode?
    return unless framework_id

    ActiveRecord.after_all_transactions_commit do
      framework = FrameworkState::Framework.find_by(framework_id: framework_id)
      next unless framework

      publishing = visible && FrameworkPublication.in_flight_for?(framework_id)
      broadcast_draft_slot(framework, :badge, "framework_activity", visible: visible)
      broadcast_draft_slot(framework, :publish, Views::Frameworks::Explorer::DraftStatus::PUBLISHERS_STREAM,
                           visible: visible, publishing: publishing)
    rescue => e
      Rails.logger.warn("[#{self.class.name}] Draft status broadcast failed: #{e.message}")
    end
  end

  DRAFT_SLOT_TARGETS = {
    badge: Views::Frameworks::Explorer::DraftStatus::BADGE_ID,
    publish: Views::Frameworks::Explorer::DraftStatus::PUBLISH_ID
  }.freeze

  def broadcast_draft_slot(framework, slot, stream, visible:, publishing: false)
    Turbo::StreamsChannel.broadcast_replace_to(
      stream, framework.framework_id,
      target: DRAFT_SLOT_TARGETS.fetch(slot),
      html: ApplicationController.render(
        Views::Frameworks::Explorer::DraftStatus.new(
          framework: framework, slot: slot, visible: visible, publishing: publishing
        ),
        layout: false
      )
    )
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
