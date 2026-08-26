# frozen_string_literal: true

# Shared "Discuss…" affordances — the grid's entry point to a clarification
# (§12a): an anchored question that proposes nothing.
#
# Every trigger is a plain button opening the root-mounted
# `request-clarification-modal` (Lesson 19), carrying its anchor in a `discuss_*`
# dataset the `request-clarification-form` controller reads. Deliberately NOT a
# Stimulus mount of its own: the edit-mode matrix already carries thousands of
# controller mounts, and one per cell is the wrong direction (Lesson 23).
module Views::Frameworks::Explorer::Concerns::DiscussTrigger
  MODAL_ID = "request-clarification-modal"

  # @param capability_id [String, nil]
  # @param context_label [String] where in the framework the question lands,
  #   e.g. "Strategic Thinking · L5"
  # @param level_ordinal [Integer, nil] when the trigger names one cell
  # @param illustration_id [String, nil] when the trigger names one example
  # @param level_options [Array<Hash>, nil] `[{ ordinal:, label: }]` — offered as
  #   a select when the trigger has no single cell in mind (the capability row)
  # @return [Hash] data attributes for a `click->modal#open` trigger
  def discuss_trigger_data(context_label:, capability_id: nil, level_ordinal: nil,
                           illustration_id: nil, level_options: nil)
    {
      action: "click->modal#open",
      modal_target_id: MODAL_ID,
      discuss_capability_id: capability_id,
      discuss_illustration_id: illustration_id,
      discuss_level_ordinal: level_ordinal,
      discuss_context_label: context_label,
      discuss_level_options: level_options.presence&.to_json
    }.compact
  end

  # Hover-revealed speech-bubble button — the in-grid trigger (expectation
  # cells). `reveal_classes` carry the caller's `group/…` hover token, which
  # must be a literal in the caller's source (Lesson 12).
  #
  # @param reveal_classes [String]
  # @param label [String] accessible name
  def render_discuss_button(reveal_classes:, label:, **anchor)
    button(
      type: "button",
      aria: { label: label },
      title: label,
      class: "shrink-0 rounded p-0.5 text-gray-400 hover:text-gray-700 dark:hover:text-gray-200 " \
             "cursor-pointer transition-opacity focus-visible:opacity-100 " \
             "focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-primary/60 " \
             "#{reveal_classes}",
      data: discuss_trigger_data(**anchor)
    ) { discuss_icon }
  end

  # Menu item form — for the kebabs (capability row, illustration), where the
  # kebab is the right-most control and absorbs secondary actions.
  def render_discuss_menu_item(**anchor)
    button(
      type: "button",
      role: "menuitem",
      class: kebab_item_classes("text-gray-700 dark:text-gray-200"),
      data: discuss_trigger_data(**anchor)
    ) { "Discuss…" }
  end

  # Speech bubble — the same content-language glyph the open-clarification
  # indicator uses, so "ask" and "there's a question here" read as one family.
  def discuss_icon
    svg(
      xmlns: "http://www.w3.org/2000/svg",
      class: "w-3.5 h-3.5",
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
  end
end
