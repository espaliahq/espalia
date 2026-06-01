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
    button(
      type: "button",
      class: "shrink-0 flex items-center gap-1.5 px-3 py-1.5 rounded-md " \
             "bg-gray-100 dark:bg-gray-800 text-sm font-medium " \
             "text-gray-700 dark:text-gray-300 hover:bg-gray-200 " \
             "dark:hover:bg-gray-700 transition-colors",
      data: { action: "click->activity-pane#toggle",
              activity_pane_target: "toggle" },
      aria: { expanded: "false", controls: "assessment-activity-pane" }
    ) do
      span { "Activity" }
      span(class: "text-xs font-mono text-gray-600 dark:text-gray-300") { @entry_count.to_s }
    end
  end
end
