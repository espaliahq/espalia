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
    render Components::Kit::Button.new(
      variant: :subtle, touch: true,
      data: { action: "click->activity-pane#toggle", activity_pane_target: "toggle" },
      aria: { expanded: "false", controls: Views::CalibrationSessions::LogPane::PANE_ID }
    ) do
      span { "Session log" }
      span(class: "text-xs font-mono text-muted") { @entry_count.to_s }
    end
  end
end
