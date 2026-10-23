# frozen_string_literal: true

# Reusable rendering logic for pending suggestion visual affordances.
#
# Include in any Phlex view component that renders framework entity text
# to apply consistent decoration when pending suggestions exist.
#
# The amber wavy underline (the "wiggle") is the **universal signal that text
# differs from the published framework** — whether it's a pending suggestion or a
# change already applied into the open draft (added/edited in draft, not yet
# published). There is NO separate "New in draft" pill: the wiggle says it. See
# docs/guidelines/framework-explorer.md → "Pending-change vocabulary".
#
# Visual language:
# - Pending text edit (the common case): render an inline character-level
#   diff — added graphemes get a light-blue wavy underline, removed
#   graphemes a strikethrough. When the diff has more than
#   {Frameworks::SuggestionDiff::MAX_CHANGE_RUNS} change runs the view
#   collapses to the proposed text styled with the light-blue squiggle
#   (readers can open the context pane to see the full side-by-side).
# - Pending create (illustrations / expectations) or **added-in-draft** entity:
#   amber wavy underline (the wiggle) on the text.
# - Pending delete: red strikethrough on existing text.
#
module Views::Frameworks::Explorer::Concerns::SuggestionDecoration
  PENDING_EDIT_CLASSES = "underline decoration-suggestion-edit decoration-wavy decoration-2 underline-offset-4"
  PENDING_DELETE_CLASSES = "line-through decoration-suggestion-delete decoration-2"
  PENDING_ADD_CLASSES = "underline decoration-suggestion-add decoration-wavy decoration-2 underline-offset-4 text-suggestion-add"
  PENDING_REMOVE_CLASSES = "line-through decoration-current/60 decoration-2 text-muted"
  PROPOSED_TEXT_CLASSES = PENDING_ADD_CLASSES

  # Returns Tailwind CSS classes for an entity wrapper when there are
  # pending delete suggestions. Pending-edit decoration is no longer
  # applied at the wrapper level — {#render_inline_diff} handles it inline.
  #
  # @param pending_edit_count [Integer] retained for signature compatibility;
  #   inline-diff rendering is applied per-segment by {#render_inline_diff}.
  # @param pending_delete_count [Integer] number of pending delete suggestions
  # @return [String] space-separated CSS classes, or empty string
  def suggestion_text_classes(pending_edit_count: 0, pending_delete_count: 0, added_in_draft: false)
    return PENDING_DELETE_CLASSES if pending_delete_count > 0

    # Pending edit decoration is rendered inline by #render_inline_diff so
    # the proposal is visible in situ. If no inline-diff path is available
    # (e.g. an entity type we haven't wired yet), fall back to the legacy
    # amber underline so the author still sees something.
    return PENDING_EDIT_CLASSES if pending_edit_count > 0

    # A change already applied into the open draft (not yet published) carries
    # the same wiggle — it differs from the published framework. No pill.
    return PENDING_EDIT_CLASSES if added_in_draft

    ""
  end

  # Tooltip for a draft-applied entity's wiggle, so the "differs from published"
  # meaning is conveyed non-visually (the wiggle replaced the explicit pill).
  #
  # @param added_in_draft [Boolean]
  # @return [String, nil]
  def draft_change_title(added_in_draft)
    "Not yet published — appears in the published framework once this draft is published" if added_in_draft
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
  # @param interactive [Boolean] wrap in the open-card click affordance. Pass
  #   false when the diff renders inside another interactive widget (the
  #   category name sits in the header's role=button focus target — nesting a
  #   second button-role widget there breaks its accessible name and hijacks
  #   the focus-category click).
  # @return [Boolean] true if inline content was emitted
  def render_inline_diff(original:, pending_edit:, interactive: true)
    return false if pending_edit.nil?

    suggestion_id = interactive ? pending_edit[:suggestion_id] : nil
    with_suggestion_click_affordance(suggestion_id) do
      render_diff_segments(original: original, pending_edit: pending_edit)
    end

    true
  end

  # Wraps decorated pending-change text in the "open this suggestion in the
  # activity pane" affordance: clicking the squiggled text opens the pane's
  # suggestion card (with its Approve / Reject controls) instead of doing
  # nothing. Dispatches through matrix#openSuggestionCard, which stops the
  # click from also toggling the row / focusing the cell. Renders the bare
  # content when there's no suggestion to open (e.g. added-in-draft wiggles).
  #
  # @param suggestion_id [String, nil]
  def with_suggestion_click_affordance(suggestion_id, &block)
    return yield if suggestion_id.blank?

    span(
      role: "button",
      tabindex: "0",
      class: "cursor-pointer rounded-xs hover:bg-warning-subtle " \
             "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus",
      title: "View this pending suggestion in the activity pane",
      data: {
        action: "click->matrix#openSuggestionCard " \
                "keydown.enter->matrix#openSuggestionCard " \
                "keydown.space->matrix#openSuggestionCard",
        suggestion_id: suggestion_id
      },
      &block
    )
  end

  # The bullet marking one illustration in an expanded-row list — several
  # illustrations under one role must read as discrete examples, and pending
  # ghosts must stay dimensionally identical to settled items so the list
  # never goes ragged.
  #
  # @param color_classes [String] the fill (gray for settled, amber for pending)
  # @return [void]
  def render_illustration_marker(color_classes)
    span(class: "mt-1.5 w-1 h-1 rounded-full shrink-0 #{color_classes}",
         aria: { hidden: "true" }) { }
  end

  # Emits the character-level diff spans for a pending edit (or the proposed
  # text alone past the density fallback). Split out of {#render_inline_diff}
  # so the click affordance can wrap exactly this content.
  #
  # @param original [String]
  # @param pending_edit [Hash] :suggested_value at minimum
  # @return [void]
  def render_diff_segments(original:, pending_edit:)
    proposed = pending_edit[:suggested_value].to_s
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
  end

  # Small muted speech-bubble marking an open clarification discussion on the
  # entity (edit mode only — the suggestions map is empty in view mode, so
  # callers never see a positive count there). This is the CONTENT language
  # (glyphs — same vocabulary as the assessment level chips), deliberately NOT
  # the pending-change wiggle: a clarification proposes no change.
  #
  # The glyph opens the most recent discussion's card (the same
  # `suggestion:open-card` path the squiggle uses; `matrix#openSuggestionCard`
  # stops the row/cell click itself). Opening "the newest" is safe at any count
  # because the card lists its siblings — the rest are one click away rather
  # than stranded, which was a real reported dead end.
  #
  # @param count [Integer] open clarifications on the entity
  # @param suggestion_id [String, nil] the discussion the glyph opens
  # @return [void] renders nothing when count is zero
  def render_clarification_glyph(count, suggestion_id: nil)
    return unless count.to_i.positive?

    noun = "open #{'discussion'.pluralize(count)}"
    title = suggestion_id ? "#{count} #{noun} — view" : "#{count} #{noun} — see the activity pane"
    attrs = {
      class: "ml-1 align-middle",
      title: title,
      aria: { label: title },
      data: { glyph: "clarification" }
    }

    if suggestion_id
      attrs[:class] += " cursor-pointer hover:bg-neutral-muted " \
                       "focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-focus"
      attrs[:role] = "button"
      attrs[:tabindex] = "0"
      attrs[:data] = attrs[:data].merge(
        suggestion_id: suggestion_id,
        action: "click->matrix#openSuggestionCard " \
                "keydown.enter->matrix#openSuggestionCard " \
                "keydown.space->matrix#openSuggestionCard"
      )
    else
      attrs[:role] = "img"
    end

    render Components::Kit::Badge.new(count.to_i > 1 ? count.to_s : "", leading_icon: "discuss", **attrs)
  end
end
