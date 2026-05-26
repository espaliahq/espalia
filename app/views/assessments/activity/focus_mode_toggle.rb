# frozen_string_literal: true

# Two-segment Highlight | Filter toggle. Switches how the feed reacts
# when the matrix focuses a row or cell:
# - Highlight: matching entries get an amber accent and a quiet
#   background; non-matching dim slightly.
# - Filter: only matching entries render; the rest are hidden.
#
# Mode is sticky in `assessment_activity_focus_mode` cookie (1-year,
# SameSite=Lax) so the user's last preference carries across sessions.
# Default is "filter".
#
class Views::Assessments::Activity::FocusModeToggle < Views::Base
  MODES = [
    { value: "highlight", label: "Highlight" },
    { value: "filter",    label: "Filter" }
  ].freeze

  def view_template
    div(
      class: "inline-flex items-center gap-px rounded-md border border-gray-200 " \
             "dark:border-gray-700 p-0.5 text-[11px] font-medium",
      role: "group",
      aria_label: "Activity feed focus mode"
    ) do
      MODES.each { |mode| render_segment(mode) }
    end
  end

  private

  def render_segment(mode)
    button(
      type: "button",
      class: "px-2 py-0.5 rounded transition-colors " \
             "aria-pressed:bg-primary aria-pressed:text-white " \
             "aria-[pressed=false]:text-gray-600 dark:aria-[pressed=false]:text-gray-300 " \
             "aria-[pressed=false]:hover:bg-gray-100 dark:aria-[pressed=false]:hover:bg-gray-700",
      data: {
        activity_feed_target: "modeSegment",
        activity_feed_mode_param: mode[:value],
        action: "click->activity-feed#setMode"
      },
      aria: { pressed: mode[:value] == "filter" ? "true" : "false" }
    ) { mode[:label] }
  end
end
