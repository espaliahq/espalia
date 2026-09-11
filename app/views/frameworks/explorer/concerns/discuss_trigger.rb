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
  # The Discuss controls are hover-cluster members, so every host needs the
  # cluster's data helpers — pulled in here rather than repeated at ~15 call
  # sites where forgetting one is a NoMethodError at render time.
  def self.included(base)
    super
    base.include(Views::Frameworks::Explorer::Concerns::HoverCluster)
    base.include(Views::Frameworks::Explorer::Concerns::MenuItems)
  end

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
  # cells). Reveals with the rest of its entity's cluster and is hidden on
  # coarse pointers, where the kebab's "Discuss…" item takes over
  # ({HoverCluster}).
  #
  # @param scope [String] hover-cluster scope
  # @param label [String] accessible name
  def render_discuss_button(scope:, label:, **anchor)
    button(
      type: "button",
      aria: { label: label },
      title: label,
      class: "explorer-discuss",
      data: cluster_control_data(scope).merge(discuss_trigger_data(**anchor))
    ) { discuss_icon }
  end

  # Menu-node form — for the kebabs, where the kebab is the right-most control
  # and absorbs secondary actions (and is the only control on a touch device).
  #
  # @return [Hash] one item node for {MenuItems}
  def discuss_menu_item(**anchor)
    menu_item_node("Discuss…", **discuss_trigger_data(**anchor))
  end

  # Speech bubble — the same content-language glyph the open-clarification
  # indicator uses, so "ask" and "there's a question here" read as one family.
  def discuss_icon
    icon("discuss")
  end
end
