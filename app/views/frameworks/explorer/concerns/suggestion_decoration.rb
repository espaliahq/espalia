# frozen_string_literal: true

# Reusable rendering logic for pending suggestion visual affordances.
#
# Include in any Phlex view component that renders framework entity text
# to apply consistent decoration when pending suggestions exist.
#
# Visual language:
# - Pending text edit (the common case): render an inline character-level
#   diff — added graphemes get a light-blue wavy underline, removed
#   graphemes a strikethrough. When the diff has more than
#   {Frameworks::SuggestionDiff::MAX_CHANGE_RUNS} change runs the view
#   collapses to the proposed text styled with the light-blue squiggle
#   (readers can open the context pane to see the full side-by-side).
# - Pending create (illustrations): amber wavy underline on the proposed
#   ghost-row text — rendered by PendingIllustrationFrame, unchanged.
# - Pending delete: red strikethrough on existing text.
#
module Views::Frameworks::Explorer::Concerns::SuggestionDecoration
  PENDING_EDIT_CLASSES = "underline decoration-amber-400 decoration-wavy decoration-2 underline-offset-4"
  PENDING_DELETE_CLASSES = "line-through decoration-red-400 decoration-2"
  PENDING_ADD_CLASSES = "underline decoration-sky-400 decoration-wavy decoration-2 underline-offset-4 text-sky-700 dark:text-sky-300"
  PENDING_REMOVE_CLASSES = "line-through decoration-current/60 decoration-2 text-gray-500 dark:text-gray-400"
  PROPOSED_TEXT_CLASSES = PENDING_ADD_CLASSES

  # Returns Tailwind CSS classes for an entity wrapper when there are
  # pending delete suggestions. Pending-edit decoration is no longer
  # applied at the wrapper level — {#render_inline_diff} handles it inline.
  #
  # @param pending_edit_count [Integer] retained for signature compatibility;
  #   inline-diff rendering is applied per-segment by {#render_inline_diff}.
  # @param pending_delete_count [Integer] number of pending delete suggestions
  # @return [String] space-separated CSS classes, or empty string
  def suggestion_text_classes(pending_edit_count: 0, pending_delete_count: 0)
    return PENDING_DELETE_CLASSES if pending_delete_count > 0

    # Pending edit decoration is rendered inline by #render_inline_diff so
    # the proposal is visible in situ. If no inline-diff path is available
    # (e.g. an entity type we haven't wired yet), fall back to the legacy
    # amber underline so the author still sees something.
    return PENDING_EDIT_CLASSES if pending_edit_count > 0

    ""
  end

  # Renders the inline diff for a pending text-edit suggestion. Emits a
  # sequence of spans combining the original and proposed text with
  # added / removed graphemes styled; falls back to the proposed text
  # styled as the squiggled-add when the diff is too dense. Returns
  # `false` when there is nothing to render so callers can decide
  # whether to fall through to plain text.
  #
  # @param original [String] current entity text (from the read model)
  # @param pending_edit [Hash, nil] :suggested_value, :suggestion_id, :created_at
  # @return [Boolean] true if inline content was emitted
  def render_inline_diff(original:, pending_edit:)
    return false if pending_edit.nil?

    proposed = pending_edit[:suggested_value].to_s
    return false if proposed.blank?

    diff = Frameworks::SuggestionDiff.call(original: original.to_s, proposed: proposed)

    if diff == :fallback
      span(class: PROPOSED_TEXT_CLASSES) { proposed }
    else
      diff.each do |seg|
        case seg[:kind]
        when :equal
          plain seg[:text]
        when :added
          span(class: PENDING_ADD_CLASSES) { seg[:text] }
        when :removed
          span(class: PENDING_REMOVE_CLASSES) { seg[:text] }
        end
      end
    end

    true
  end
end
