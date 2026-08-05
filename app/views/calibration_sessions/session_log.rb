# frozen_string_literal: true

# The session log — the follow-through artifact
# (docs/architecture/calibration-sessions.md → "Outcomes"): expectation
# flags with the live status of the framework clarification each raised,
# revisit requests with rating-change-based resolution, and the free-text
# minutes, plus the note composer while the session is live. Rendered on
# the session page for live AND closed sessions — the closed page is the
# opening slide of the next session.
#
# Presented in the product's ACTIVITY-PANEL form (the framework explorer's
# feed and the assessment sidebar): one reverse-chronological list, each
# entry a coloured kind dot + summary + context + secondary + actor·time
# footer, with client-side filter chips. A session's story is one thread —
# a flag, the note it prompted, the revisit it produced — and the old
# split-by-type sections hid that ordering.
class Views::CalibrationSessions::SessionLog < Views::Base
  include Phlex::Rails::Helpers::TimeAgoInWords

  # The most recent outcomes to render. SessionOutcomes already caps the
  # stream read; this caps the HTML, which was ~530KB at 800 entries on a
  # page that re-renders server-side for every pane swap.
  RENDER_LIMIT = 100

  CLARIFICATION_STATUS = {
    "pending"   => [ "Discussion open", "text-amber-700 dark:text-amber-300" ],
    "resolved"  => [ "Resolved", "text-green-700 dark:text-green-300" ],
    "withdrawn" => [ "Withdrawn", "text-gray-600 dark:text-gray-300" ]
  }.freeze

  # Kind → dot colour, borrowing the framework feed's vocabulary: amber
  # raises a question, sky is a request, indigo is editorial.
  KIND_DOT = {
    "expectation_flagged" => "bg-amber-500",
    "revisit_requested"   => "bg-sky-500",
    "note_recorded"       => "bg-indigo-500"
  }.freeze

  KIND_GROUP = {
    "expectation_flagged" => "flags",
    "revisit_requested"   => "revisits",
    "note_recorded"       => "notes"
  }.freeze

  CHIPS = [
    { value: "all",      label: "All" },
    { value: "flags",    label: "Flags" },
    { value: "revisits", label: "Revisits" },
    { value: "notes",    label: "Notes" }
  ].freeze

  # @param session [CalibrationSession]
  # @param log [Hash] `{ entries:, suggestions:, capability_names:, acted: }`
  #   — entries from {CalibrationSessions::SessionOutcomes#entries};
  #   suggestions maps suggestion_id → FrameworkState::SuggestedEdit;
  #   acted is a Set of [person_id, capability_stable_id, level_ordinal]
  #   whose manager rating changed after the ask.
  # @param people [Hash{String => Person}]
  # @param can_note [Boolean] live session + facilitator/admin
  # @param note_fields [Array<Array(String, String)>] extra hidden
  #   name/value pairs for the composer — the drill-in uses these to anchor
  #   the note to the capability on screen and to come back here afterwards
  def initialize(session:, log:, people:, can_note:, note_fields: [])
    @session = session
    @log = log
    @people = people
    @can_note = can_note
    @note_fields = note_fields
  end

  # Panel CONTENT — the surrounding surface is the side panel
  # ({Views::CalibrationSessions::LogPane}), matching how the assessment
  # feed renders inside its aside.
  def view_template
    div(class: "p-4", id: "session-log", data: { controller: "framework-activity" }) do
      header
      if entries.empty?
        empty_state
      else
        ul(class: "mt-3 space-y-1") do
          entries.each { |entry| entry_row(entry) }
        end
        older_note if truncated?
      end
      note_composer if @can_note
    end
  end

  private

  def entries
    @entries ||= (@log[:entries] || []).first(RENDER_LIMIT)
  end

  def truncated?
    (@log[:entries] || []).size > RENDER_LIMIT
  end

  # Title + close in one row (the pane has no separate chrome), chips
  # below — the assessment feed's arrangement.
  def header
    div(class: "flex items-center justify-between gap-2") do
      h2(class: "text-sm font-semibold uppercase tracking-wide text-gray-600 dark:text-gray-300") do
        "Session log"
      end
      button(
        type: "button",
        class: "inline-flex h-11 w-11 shrink-0 items-center justify-center rounded-md " \
               "text-gray-600 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-700",
        data: { action: "click->activity-pane#close" },
        aria: { label: "Close the session log" }
      ) { span(aria: { hidden: "true" }) { "✕" } }
    end
    div(class: "mt-2") { filter_chips } if entries.any?
  end

  def filter_chips
    div(class: "flex flex-wrap gap-1 text-[11px] font-medium",
        role: "group", aria_label: "Filter the session log by kind") do
      CHIPS.each { |chip| render_chip(chip) }
    end
  end

  def render_chip(chip)
    button(
      type: "button",
      class: "px-2 py-1 rounded-md transition-colors " \
             "aria-pressed:bg-primary aria-pressed:text-white " \
             "aria-[pressed=false]:bg-gray-100 dark:aria-[pressed=false]:bg-gray-800 " \
             "aria-[pressed=false]:text-gray-600 dark:aria-[pressed=false]:text-gray-300 " \
             "aria-[pressed=false]:hover:bg-gray-200 dark:aria-[pressed=false]:hover:bg-gray-700",
      data: {
        framework_activity_target: "filterChip",
        framework_activity_filter_param: chip[:value],
        action: "click->framework-activity#setFilter"
      },
      aria: { pressed: chip[:value] == "all" ? "true" : "false" }
    ) { chip[:label] }
  end

  # Says so rather than silently truncating — a log that quietly stops is
  # indistinguishable from one with nothing older in it.
  def older_note
    p(class: "mt-3 text-[11px] text-gray-600 dark:text-gray-300") do
      "Showing the #{RENDER_LIMIT} most recent outcomes."
    end
  end

  def empty_state
    p(class: "mt-2 text-sm text-gray-600 dark:text-gray-300") do
      "No outcomes recorded yet — flags, revisit requests, and notes land here."
    end
  end

  # One feed entry, in the product's activity shape.
  def entry_row(entry)
    li(
      class: "flex gap-2 text-xs text-gray-700 dark:text-gray-300 rounded -mx-2 px-2 py-1.5 " \
             "data-[hidden=true]:hidden",
      data: {
        framework_activity_target: "entry",
        kind_group: KIND_GROUP.fetch(entry[:kind], "all")
      }
    ) do
      span(class: "mt-1 w-2 h-2 rounded-full shrink-0 #{KIND_DOT.fetch(entry[:kind], 'bg-gray-400')}",
           aria: { hidden: "true" }) { }
      div(class: "min-w-0 flex-1") do
        div(class: "flex flex-wrap items-center gap-2") do
          p(class: "font-medium text-gray-900 dark:text-gray-100") { summary_text(entry) }
          status_badge(entry)
        end
        context = context_text(entry)
        p(class: "mt-0.5 text-[11px] text-gray-600 dark:text-gray-300") { context } if context
        secondary = secondary_text(entry)
        if secondary
          p(class: "mt-0.5 text-[11px] text-gray-600 dark:text-gray-300 whitespace-pre-wrap") { secondary }
        end
        resolution_line(entry)
        footer(entry)
      end
    end
  end

  def summary_text(entry)
    case entry[:kind]
    when "expectation_flagged" then "⚑ Flagged an expectation as unclear"
    when "revisit_requested"   then "Asked #{person_name(entry[:rater_id])} to revisit a rating"
    else                            "Recorded a note"
    end
  end

  # Where in the session this happened — never truncated (§9's rule).
  def context_text(entry)
    case entry[:kind]
    when "expectation_flagged"
      "#{capability_name(entry[:capability_stable_id])} · L#{entry[:level_ordinal]}"
    when "revisit_requested"
      "#{person_name(entry[:person_id])} · #{capability_name(entry[:capability_stable_id])} " \
        "· L#{entry[:level_ordinal]}"
    else
      anchors = [
        (capability_name(entry[:capability_stable_id]) if entry[:capability_stable_id]),
        (person_name(entry[:person_id]) if entry[:person_id])
      ].compact
      anchors.any? ? anchors.join(" · ") : nil
    end
  end

  def secondary_text(entry)
    case entry[:kind]
    when "expectation_flagged" then entry[:reason].presence
    when "revisit_requested"   then entry[:note].presence
    else                            entry[:body].presence
    end
  end

  # The live state of what the entry set in motion: the clarification's
  # status, or whether the rater has since moved the rating.
  def status_badge(entry)
    case entry[:kind]
    when "expectation_flagged" then clarification_badge(entry)
    when "revisit_requested"   then revisit_badge(entry)
    end
  end

  def clarification_badge(entry)
    suggestion = @log[:suggestions][entry[:suggestion_id]]
    return unless suggestion

    label, classes = CLARIFICATION_STATUS.fetch(
      suggestion.status, [ suggestion.status.humanize, "text-gray-600 dark:text-gray-300" ]
    )
    span(class: "text-[11px] font-medium #{classes}") { label }
  end

  def revisit_badge(entry)
    if acted?(entry)
      span(class: "text-[11px] font-medium text-green-700 dark:text-green-300") { "Rating revisited" }
    else
      span(class: "text-[11px] font-medium text-amber-700 dark:text-amber-300") { "Open" }
    end
  end

  def resolution_line(entry)
    return unless entry[:kind] == "expectation_flagged"

    suggestion = @log[:suggestions][entry[:suggestion_id]]
    return unless suggestion&.status == "resolved" && suggestion.reviewer_comment.present?

    p(class: "mt-0.5 text-[11px] italic text-gray-600 dark:text-gray-300") do
      "Resolution: #{suggestion.reviewer_comment}"
    end
  end

  def acted?(entry)
    @log[:acted].include?(
      [ entry[:person_id], entry[:capability_stable_id], entry[:level_ordinal] ]
    )
  end

  def footer(entry)
    div(class: "mt-1 text-[10px] text-gray-600 dark:text-gray-300") do
      bits = [ person_name(entry[:actor_id]),
               (entry[:at] ? "#{time_ago_in_words(entry[:at])} ago" : nil) ].compact
      span { bits.join(" · ") }
    end
  end

  def note_composer
    form(
      action: calibration_session_notes_path(@session),
      method: "post",
      class: "mt-4 space-y-2",
      # The panel sits outside the drill-in's pane frame, so its carried
      # state is refreshed from the live URL at submit time.
      data: (@note_fields.any? ? { action: "submit->calibration-pane#stampState" } : {})
    ) do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      @note_fields.each { |name, value| input(type: "hidden", name: name, value: value) }
      label(for: "session-note", class: "block text-xs font-semibold uppercase " \
                                        "text-gray-600 dark:text-gray-300") { "Add a note" }
      textarea(
        id: "session-note", name: "body", rows: "2", required: true,
        class: "block w-full rounded-md border border-gray-300 dark:border-gray-600 " \
               "bg-white dark:bg-gray-800 px-3 py-2 text-sm text-gray-900 dark:text-white " \
               "focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-primary",
        placeholder: "A minute for the room — e.g. “add Priya to the org-wide session”"
      )
      button(
        type: "submit",
        class: "inline-flex items-center rounded-md bg-primary px-3 py-2 text-sm " \
               "font-semibold text-white hover:bg-primary/80 transition-colors"
      ) { "Record note" }
    end
  end

  def capability_name(stable_id)
    @log[:capability_names][stable_id] || "Capability"
  end

  def person_name(person_id)
    (person_id && @people[person_id]&.name) || "Unknown"
  end
end
