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
    render Components::Kit::SegmentedControl.new(label: "Activity feed focus mode", size: :sm) do |control|
      MODES.each do |mode|
        control.segment(mode[:label], selected: mode[:value] == "filter", data: {
          activity_feed_target: "modeSegment",
          activity_feed_mode_param: mode[:value],
          action: "click->activity-feed#setMode"
        })
      end
    end
  end
end
