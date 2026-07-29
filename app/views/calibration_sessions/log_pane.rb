# frozen_string_literal: true

# The session log as a right-hand activity SIDE PANEL — the product's
# established pattern (the framework explorer's context pane, the
# assessment screen's activity sidebar). Rendered on both the session
# page and the capability drill-in, so the room can raise an outcome and
# watch it land without leaving the context they're discussing.
#
# Inline and sticky on lg+; a fixed overlay below that, so the grid keeps
# its full width on a narrow screen. Open/closed lives in the
# `activity-pane` controller (its own cookie, so it doesn't share the
# assessment sidebar's preference).
class Views::CalibrationSessions::LogPane < Views::Base
  PANE_ID = "calibration-log-pane"

  # One preference per SURFACE, not per feature: the two pages have
  # genuinely different width economics (the drill-in's grid wants the
  # room), so a single slot would let a choice made on one silently
  # override the other's documented default.
  SESSION_COOKIE = "calibration_log_pane_open"
  DRILL_IN_COOKIE = "calibration_drill_in_log_pane_open"

  # @param session [CalibrationSession]
  # @param log [Hash] SessionLog's log hash
  # @param people [Hash{String => Person}]
  # @param can_note [Boolean]
  def initialize(session:, log:, people:, can_note:, note_fields: [])
    @session = session
    @log = log
    @people = people
    @can_note = can_note
    @note_fields = note_fields
  end

  def view_template
    aside(
      id: PANE_ID,
      class: "hidden bg-gray-50 dark:bg-gray-800 overflow-auto " \
             "border border-gray-200 dark:border-gray-700 " \
             "max-lg:fixed max-lg:inset-y-0 max-lg:right-0 max-lg:z-30 " \
             "max-lg:w-80 max-lg:shadow-xl max-lg:border-l max-lg:rounded-none " \
             "lg:shrink-0 lg:w-80 lg:rounded-xl " \
             "lg:sticky lg:self-start lg:max-h-[calc(100vh-2rem)]",
      style: "top: 1rem",
      data: { activity_pane_target: "pane", pane_state: "closed" }
    ) do
      render Views::CalibrationSessions::SessionLog.new(
        session: @session, log: @log, people: @people, can_note: @can_note,
        note_fields: @note_fields
      )
    end
  end
end
