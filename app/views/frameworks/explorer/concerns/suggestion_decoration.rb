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
  PENDING_EDIT_CLASSES = "underline decoration-amber-400 decoration-wavy decoration-2 underline-offset-4"
  PENDING_DELETE_CLASSES = "line-through decoration-red-400 decoration-2"
  PENDING_ADD_CLASSES = "underline decoration-sky-400 decoration-wavy decoration-2 underline-offset-4 text-sky-700 dark:text-sky-300"
  PENDING_REMOVE_CLASSES = "line-through decoration-current/60 decoration-2 text-gray-600 dark:text-gray-300"
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
      class: "cursor-pointer rounded-xs hover:bg-amber-100/60 dark:hover:bg-amber-900/30 " \
             "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/60",
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
  # The glyph must reach EVERYTHING it counts. With exactly one discussion the
  # caller passes its `suggestion_id` and the glyph opens that card (the same
  # `suggestion:open-card` path the squiggle uses). With several there is no
  # "the" discussion, so the caller passes `cell:` instead and the glyph opens
  # the capability-focused feed, which lists them all — passing a lone "latest"
  # id at any count strands the rest, which was a real reported dead end.
  # Either way `matrix#…` stops the row/cell click itself.
  #
  # @param count [Integer] open clarifications on the entity
  # @param suggestion_id [String, nil] the sole discussion, when there is one
  # @param cell [Hash, nil] `{ capability_id:, level_ordinal: }` — the fallback
  #   target when several discussions share the entity
  # @return [void] renders nothing when count is zero
  def render_clarification_glyph(count, suggestion_id: nil, cell: nil)
    return unless count.to_i.positive?

    noun = "open #{'discussion'.pluralize(count)}"
    title =
      if suggestion_id then "#{count} #{noun} — view"
      elsif cell then "#{count} #{noun} here — view them"
      else "#{count} #{noun} — see the activity pane"
      end
    attrs = {
      class: "inline-flex items-center gap-0.5 ml-1 align-middle rounded-full " \
             "bg-gray-100 dark:bg-gray-800 px-1 py-0.5 text-gray-600 dark:text-gray-300 shrink-0",
      title: title,
      aria: { label: title },
      data: { glyph: "clarification" }
    }

    if suggestion_id || cell
      attrs[:class] += " cursor-pointer hover:bg-gray-200 dark:hover:bg-gray-700 " \
                       "focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-primary/60"
      attrs[:role] = "button"
      attrs[:tabindex] = "0"
      # One discussion opens straight into its card. Several open the pane
      # focused on the cell, which lists them all — a single id would strand
      # every discussion the count advertises but the click can't reach.
      action = suggestion_id ? "matrix#openSuggestionCard" : "matrix#openCellDiscussions"
      attrs[:data] = attrs[:data].merge(
        suggestion_id: suggestion_id,
        capability_id: cell && cell[:capability_id],
        level_ordinal: cell && cell[:level_ordinal],
        action: "click->#{action} keydown.enter->#{action} keydown.space->#{action}"
      ).compact
    else
      attrs[:role] = "img"
    end

    span(**attrs) do
      svg(
        xmlns: "http://www.w3.org/2000/svg",
        class: "w-2.5 h-2.5",
        fill: "none", viewBox: "0 0 24 24", stroke: "currentColor", stroke_width: "2",
        aria: { hidden: "true" }
      ) do |s|
        s.path(
          stroke_linecap: "round",
          stroke_linejoin: "round",
          d: "M21 11.5a8.38 8.38 0 01-.9 3.8 8.5 8.5 0 01-7.6 4.7 8.38 8.38 0 01-3.8-.9L3 21l1.9-5.7a8.38 " \
             "8.38 0 01-.9-3.8 8.5 8.5 0 014.7-7.6 8.38 8.38 0 013.8-.9h.5a8.48 8.48 0 018 8v.5z"
        )
      end
      span(class: "text-[9px] font-medium leading-none") { count.to_s } if count.to_i > 1
    end
  end
end
