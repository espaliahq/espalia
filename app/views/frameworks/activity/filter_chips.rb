# frozen_string_literal: true

# Segmented filter chips above the framework activity feed. Switches the
# visible entry groups between All / Suggestions / Edits / Structural /
# Lifecycle / Collaborators via the `framework_activity` Stimulus controller
# (purely client-side — DOM filter, no server round-trip).
#
class Views::Frameworks::Activity::FilterChips < Views::Base
  CHIPS = [
    { value: "all",           label: "All" },
    { value: "suggestions",   label: "Suggestions" },
    { value: "edits",         label: "Edits" },
    { value: "structural",    label: "Structural" },
    { value: "lifecycle",     label: "Lifecycle" },
    { value: "collaborators", label: "Collaborators" }
  ].freeze

  def view_template
    div(
      class: "flex flex-wrap gap-1 text-[11px] font-medium",
      role: "group",
      aria_label: "Filter activity by kind"
    ) do
      CHIPS.each { |chip| render_chip(chip) }
    end
  end

  private

  def render_chip(chip)
    render Components::Kit::Chip.new(
      chip[:label],
      pressed: chip[:value] == "all",
      data: {
        framework_activity_target: "filterChip",
        framework_activity_filter_param: chip[:value],
        action: "click->framework-activity#setFilter"
      }
    )
  end
end
