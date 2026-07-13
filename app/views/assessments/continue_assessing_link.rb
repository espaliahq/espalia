# frozen_string_literal: true

# Shared "jump to a capability cell" anchor — the `continue-assessing`
# Stimulus bridge dispatched as a window event so the matrix controller
# (in a different Turbo Frame scope) can focus + scroll the target cell.
#
# One component so the href/data-attribute contract with
# `continue_assessing_controller.js` lives in exactly one place; callers
# supply the label and visual treatment (hero CTA chip, priming CTA,
# completion-control jump chip).
#
class Views::Assessments::ContinueAssessingLink < Views::Base
  # @param capability_stable_id [String] cross-version capability UUID
  # @param level_ordinal [Integer] the level to focus
  # @param label [String] visible link text (the → arrow is appended)
  # @param classes [String] Tailwind classes for the anchor
  def initialize(capability_stable_id:, level_ordinal:, label:, classes:)
    @capability_stable_id = capability_stable_id
    @level_ordinal = level_ordinal
    @label = label
    @classes = classes
  end

  def view_template
    a(
      href: "#cell-#{@capability_stable_id}-#{@level_ordinal}",
      class: @classes,
      data: {
        controller: "continue-assessing",
        action: "click->continue-assessing#focus",
        continue_assessing_capability_stable_id_value: @capability_stable_id,
        continue_assessing_level_ordinal_value: @level_ordinal
      }
    ) do
      plain @label
      span(aria: { hidden: "true" }) { "→" }
    end
  end
end
