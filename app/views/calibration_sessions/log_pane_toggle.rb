# frozen_string_literal: true

# Header pill that opens the session-log side panel, mirroring the
# assessment screen's "Activity" toggle and the framework explorer's
# suggestions toggle: a count plus an `aria-expanded` the pane controller
# keeps in step.
class Views::CalibrationSessions::LogPaneToggle < Views::Base
  # @param entry_count [Integer] outcomes recorded so far
  def initialize(entry_count:)
    @entry_count = entry_count
  end

  def view_template
    button(
      type: "button",
      class: "shrink-0 inline-flex min-h-11 items-center gap-1.5 px-3 py-1.5 rounded-md " \
             "bg-gray-100 dark:bg-gray-800 text-sm font-medium " \
             "text-gray-700 dark:text-gray-300 hover:bg-gray-200 " \
             "dark:hover:bg-gray-700 transition-colors",
      data: { action: "click->activity-pane#toggle", activity_pane_target: "toggle" },
      aria: { expanded: "false", controls: Views::CalibrationSessions::LogPane::PANE_ID }
    ) do
      span { "Session log" }
      span(class: "text-xs font-mono text-gray-600 dark:text-gray-300") { @entry_count.to_s }
    end
  end
end
