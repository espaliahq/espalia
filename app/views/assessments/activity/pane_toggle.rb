# frozen_string_literal: true

# Header pill that toggles the activity pane open/closed.
#
# Mirrors the framework-explorer's role-pane toggle treatment: a
# button-styled element that shows the activity entry count and flips
# `aria-expanded` based on the activity-pane controller state. The
# controller (mounted on the page wrapper) owns the open/closed cookie
# and the actual show/hide of the pane element.
#
class Views::Assessments::Activity::PaneToggle < Views::Base
  # @param entry_count [Integer] total entries currently shown in the pane
  def initialize(entry_count:)
    @entry_count = entry_count
  end

  def view_template
    render Components::Kit::Button.new(
      variant: :subtle, size: :sm, compact: true,
      data: { action: "click->activity-pane#toggle", activity_pane_target: "toggle" },
      aria: { expanded: "false", controls: "assessment-activity-pane" }
    ) do
      span { "Activity" }
      span(class: "text-xs font-mono text-muted") { @entry_count.to_s }
    end
  end
end
