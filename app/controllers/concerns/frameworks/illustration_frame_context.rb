# frozen_string_literal: true

# The discussion context an {Views::Frameworks::Explorer::IllustrationFrame}
# needs but can't derive from the illustration alone.
#
# The matrix render supplies both from its in-memory suggestions map; any
# controller that swaps a single illustration frame must re-thread them, or the
# swap silently drops the example's comment glyph and its "Discuss…" context
# line (Hard-Won Lesson 13/16 class).
#
# Requires `@framework` (a FrameworkState::Framework).
module Frameworks::IllustrationFrameContext
  extend ActiveSupport::Concern

  private

  # Where this example sits — "Capability · L4 · Software Engineer example".
  #
  # @param illustration [FrameworkState::RoleIllustration]
  # @return [String, nil]
  def illustration_discuss_context_label(illustration)
    expectation = illustration.expectation
    return nil unless expectation

    "#{expectation.capability&.name} · L#{expectation.level_ordinal} · #{illustration.role&.name} example"
  end

  # Open discussions anchored on this example, newest last.
  #
  # @param illustration [FrameworkState::RoleIllustration]
  # @return [Hash] { count:, suggestion_id: }
  def illustration_clarification(illustration)
    open = FrameworkState::SuggestedEdit
      .where(framework_id: @framework.framework_id, target_entity_type: "role_illustration",
             target_entity_id: illustration.illustration_id)
      .clarifications.pending.order(:created_at, :id)

    { count: open.count, suggestion_id: open.last&.suggestion_id }
  end
end
