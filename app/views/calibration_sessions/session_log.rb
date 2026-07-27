# frozen_string_literal: true

# The session log — the follow-through artifact
# (docs/architecture/calibration-sessions.md → "Outcomes"): expectation
# flags with the live status of the framework clarification each raised,
# revisit requests with rating-change-based resolution, and the free-text
# minutes, plus the note composer while the session is live. Rendered on
# the session page for live AND closed sessions — the closed page is the
# opening slide of the next session.
class Views::CalibrationSessions::SessionLog < Views::Base
  CLARIFICATION_STATUS = {
    "pending"   => [ "Discussion open", "text-amber-700 dark:text-amber-300" ],
    "resolved"  => [ "Resolved", "text-green-700 dark:text-green-300" ],
    "withdrawn" => [ "Withdrawn", "text-gray-600 dark:text-gray-300" ]
  }.freeze

  # @param session [CalibrationSession]
  # @param log [Hash] `{ flags:, revisits:, notes:, suggestions:, capability_names:, acted: }`
  #   — flags/revisits/notes from {CalibrationSessions::SessionOutcomes};
  #   suggestions maps suggestion_id → FrameworkState::SuggestedEdit;
  #   acted is a Set of [person_id, capability_stable_id, level_ordinal]
  #   whose manager rating changed after the ask.
  # @param people [Hash{String => Person}]
  # @param can_note [Boolean] live session + facilitator/admin
  def initialize(session:, log:, people:, can_note:)
    @session = session
    @log = log
    @people = people
    @can_note = can_note
  end

  def view_template
    div(class: "mt-6", id: "session-log") do
      render Components::Kit::Card.new do |card|
        card.body do
          h2(class: "text-sm font-semibold uppercase tracking-wide text-gray-600 dark:text-gray-300") do
            "Session log"
          end
          if empty?
            p(class: "mt-2 text-sm text-gray-600 dark:text-gray-300") do
              "No outcomes recorded yet — flags, revisit requests, and notes land here."
            end
          else
            flags_section if @log[:flags].any?
            revisits_section if @log[:revisits].any?
            notes_section if @log[:notes].any?
          end
          note_composer if @can_note
        end
      end
    end
  end

  private

  def empty?
    @log[:flags].empty? && @log[:revisits].empty? && @log[:notes].empty?
  end

  def flags_section
    section_heading("Expectations flagged")
    ul(class: "mt-1.5 space-y-2") do
      @log[:flags].each { |flag| flag_row(flag) }
    end
  end

  def flag_row(flag)
    suggestion = @log[:suggestions][flag[:suggestion_id]]
    li(class: "rounded-md border border-gray-200 dark:border-gray-700 px-3 py-2 text-sm") do
      div(class: "flex flex-wrap items-center gap-2") do
        span(class: "font-medium text-gray-900 dark:text-white") do
          "⚑ #{capability_name(flag[:capability_stable_id])} · L#{flag[:level_ordinal]}"
        end
        clarification_status(suggestion)
      end
      if flag[:reason].present?
        p(class: "mt-1 text-xs text-gray-600 dark:text-gray-300") { flag[:reason] }
      end
      if suggestion&.status == "resolved" && suggestion.reviewer_comment.present?
        p(class: "mt-1 text-xs italic text-gray-600 dark:text-gray-300") do
          "Resolution: #{suggestion.reviewer_comment}"
        end
      end
      footer_line(person_name(flag[:flagged_by_id]), flag[:flagged_at])
    end
  end

  def clarification_status(suggestion)
    return unless suggestion

    label, classes = CLARIFICATION_STATUS.fetch(
      suggestion.status, [ suggestion.status.humanize, "text-gray-600 dark:text-gray-300" ]
    )
    span(class: "text-xs font-medium #{classes}") { label }
  end

  def revisits_section
    section_heading("Revisit requests")
    ul(class: "mt-1.5 space-y-2") do
      @log[:revisits].each { |revisit| revisit_row(revisit) }
    end
  end

  def revisit_row(revisit)
    acted = @log[:acted].include?(
      [ revisit[:person_id], revisit[:capability_stable_id], revisit[:level_ordinal] ]
    )
    li(class: "rounded-md border border-gray-200 dark:border-gray-700 px-3 py-2 text-sm") do
      div(class: "flex flex-wrap items-center gap-2") do
        span(class: "font-medium text-gray-900 dark:text-white") do
          "#{person_name(revisit[:rater_id])} · #{person_name(revisit[:person_id])} · " \
            "#{capability_name(revisit[:capability_stable_id])} L#{revisit[:level_ordinal]}"
        end
        if acted
          span(class: "text-xs font-medium text-green-700 dark:text-green-300") { "Rating revisited" }
        else
          span(class: "text-xs font-medium text-amber-700 dark:text-amber-300") { "Open" }
        end
      end
      p(class: "mt-1 text-xs text-gray-600 dark:text-gray-300") { revisit[:note] }
      footer_line(person_name(revisit[:requested_by_id]), revisit[:requested_at])
    end
  end

  def notes_section
    section_heading("Notes")
    ul(class: "mt-1.5 space-y-2") do
      @log[:notes].each { |note| note_row(note) }
    end
  end

  def note_row(note)
    li(class: "rounded-md border border-gray-200 dark:border-gray-700 px-3 py-2 text-sm") do
      anchors = [
        (capability_name(note[:capability_stable_id]) if note[:capability_stable_id]),
        (person_name(note[:person_id]) if note[:person_id])
      ].compact
      if anchors.any?
        p(class: "text-xs font-medium text-gray-600 dark:text-gray-300") { anchors.join(" · ") }
      end
      p(class: "text-gray-900 dark:text-white whitespace-pre-wrap") { note[:body] }
      footer_line(person_name(note[:recorded_by_id]), note[:recorded_at])
    end
  end

  def note_composer
    form(
      action: calibration_session_notes_path(@session),
      method: "post",
      class: "mt-4 space-y-2"
    ) do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
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

  def section_heading(text)
    h3(class: "mt-4 text-xs font-semibold uppercase tracking-wide text-gray-600 dark:text-gray-300") do
      text
    end
  end

  def footer_line(name, timestamp)
    bits = [ name, (timestamp && view_context.time_ago_in_words(timestamp) + " ago") ].compact
    div(class: "mt-1 text-[11px] text-gray-500 dark:text-gray-400") { bits.join(" · ") }
  end

  def capability_name(stable_id)
    @log[:capability_names][stable_id] || "Capability"
  end

  def person_name(person_id)
    (person_id && @people[person_id]&.name) || "Unknown"
  end
end
