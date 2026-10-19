# frozen_string_literal: true

require "test_helper"

# The log's render cap. A long session's outcome list is unbounded from the
# view's point of view, and every pane swap re-renders it server-side, so the
# cap is load-bearing rather than cosmetic.
class Views::CalibrationSessions::SessionLogTest < ActiveSupport::TestCase
  ACTOR_ID = "actor-1"

  def entry(index)
    {
      kind: "note_recorded", body: "Note number #{index}",
      at: Time.zone.parse("2026-08-01 09:00") + index.minutes, actor_id: ACTOR_ID
    }
  end

  def render_log(count)
    entries = Array.new(count) { |index| entry(index) }.reverse
    # Through a real view context — the entry footer uses a Rails helper.
    view_context.render(Views::CalibrationSessions::SessionLog.new(
      session: CalibrationSession.new,
      log: { entries: entries, suggestions: {}, capability_names: {}, acted: Set.new },
      people: { ACTOR_ID => Person.new(name: "Dana Dept") },
      can_note: false
    ))
  end

  def view_context
    @view_context ||= ApplicationController.new
      .tap { |controller| controller.request = ActionDispatch::TestRequest.create }
      .view_context
  end

  should "render every entry when the session is under the cap" do
    html = render_log(3)

    assert_includes html, "Note number 0"
    assert_not_includes html, "most recent entries"
  end

  should "render only the newest RENDER_LIMIT and say so" do
    limit = Views::CalibrationSessions::SessionLog::RENDER_LIMIT
    html = render_log(limit + 5)

    assert_includes html, "Note number #{limit + 4}", "the newest entry is rendered"
    assert_not_includes html, "Note number 0", "the oldest falls outside the cap"
    assert_equal limit, html.scan("Note number ").size
    assert_includes html, "Showing the #{limit} most recent entries.",
      "a truncated log says so rather than just stopping"
  end

  should "render renames, archives and restores as muted lifecycle lines" do
    at = Time.zone.parse("2026-08-01 09:00")
    html = view_context.render(Views::CalibrationSessions::SessionLog.new(
      session: CalibrationSession.new,
      log: { entries: [
        { kind: "session_restored", at: at + 2.minutes, actor_id: ACTOR_ID },
        { kind: "session_archived", at: at + 1.minute, actor_id: ACTOR_ID },
        { kind: "session_renamed", at: at, actor_id: ACTOR_ID, name: "H1 · Eng", previous_name: "Eng" }
      ], suggestions: {}, capability_names: {}, acted: Set.new },
      people: { ACTOR_ID => Person.new(name: "Dana Dept") },
      can_note: false
    ))

    assert_includes html, "Renamed to “H1 · Eng” (was “Eng”)"
    assert_includes html, "Archived the session"
    assert_includes html, "Restored the session from the archive"
    assert_equal 3, html.scan(%(data-kind-group="lifecycle")).size,
      "lifecycle lines only show under All — no chip claims them"
    assert_includes html, "No outcomes recorded yet", "housekeeping lines are not outcomes"
    assert_not_includes html, "framework-activity-target=\"filterChip\"", "no chips to filter outcomes that don't exist"
  end
end
