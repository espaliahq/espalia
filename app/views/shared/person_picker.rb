# frozen_string_literal: true

# Reusable person picker — debounced typeahead over a server-rendered
# candidates frame, quick-add suggestion chips, and client-side selection
# chips that submit as hidden inputs. The Stimulus mechanics live in
# `person_picker_controller.js` (extracted from the evidence-request
# recipient picker, which now subclasses it).
#
# Render INSIDE a form; the caller owns the endpoint the candidates frame
# fetches (which is where the search scope is authorized and enforced).
#
# @example
#   render Views::Shared::PersonPicker.new(
#     field_name: "calibration_session[participant_ids][]",
#     candidates_url: participant_candidates_calibration_sessions_path,
#     frame_id: "participant-candidates",
#     label: "Participants (raters)",
#     placeholder: "Search managers by name or email…",
#     suggestions: [ { person: person, subtitle: "6 reports" } ],
#     selected: [ { id: person.id, name: person.name } ]
#   )
class Views::Shared::PersonPicker < Views::Base
  INPUT = "mt-1 block w-full rounded-md border border-gray-300 dark:border-gray-600 " \
          "bg-white dark:bg-gray-900 px-3 py-2 text-sm text-gray-900 dark:text-white"

  # @param field_name [String] hidden-input name for selected ids (e.g. "foo[person_ids][]")
  # @param candidates_url [String] endpoint rendering a PersonPickerCandidatesFrame
  # @param frame_id [String] unique frame id when a page hosts several pickers
  # @param label [String] visible label for the search input
  # @param placeholder [String]
  # @param hint [String, nil] muted helper line under the label
  # @param suggestions [Array<Hash>] quick-add chips: { person:, subtitle: nil }
  # @param selected [Array<Hash>] pre-selected entries: { id:, name: }
  # @param empty_text [String]
  def initialize(field_name:, candidates_url:, frame_id: "person-picker-candidates",
                 label: "People", placeholder: "Search by name or email…",
                 hint: nil, suggestions: [], selected: [], empty_text: "No one selected yet.")
    @field_name = field_name
    @candidates_url = candidates_url
    @frame_id = frame_id
    @label = label
    @placeholder = placeholder
    @hint = hint
    @suggestions = suggestions
    @selected = selected
    @empty_text = empty_text
  end

  def view_template
    div(data: {
      controller: "person-picker",
      person_picker_candidates_url_value: @candidates_url,
      person_picker_field_name_value: @field_name,
      person_picker_frame_id_value: @frame_id
    }) do
      label(for: search_input_id, class: "block text-sm font-medium text-gray-900 dark:text-white") { @label }
      if @hint
        p(class: "mt-1 text-sm text-gray-600 dark:text-gray-300") { @hint }
      end

      # Results float as a dropdown over the content below (absolute inside
      # this relative wrapper) so typing never resizes the surrounding form.
      div(class: "relative") do
        input(
          id: search_input_id, type: "search", placeholder: @placeholder, class: INPUT,
          data: { person_picker_target: "search", action: "input->person-picker#search" }
        )
        div(class: "absolute left-0 right-0 top-full mt-1 z-20") do
          render Views::Shared::PersonPickerCandidatesFrame.new(frame_id: @frame_id, entries: [], query: nil)
        end
      end

      suggestions_block

      div(class: "mt-3") do
        span(class: "block text-sm font-medium text-gray-900 dark:text-white") { "Selected" }
        div(data: { person_picker_target: "selected" }, class: "mt-1 flex flex-wrap gap-2 min-h-9") do
          p(
            data: { person_picker_target: "empty" },
            class: "text-xs text-gray-600 dark:text-gray-300 #{'hidden' if @selected.any?}"
          ) { @empty_text }
          @selected.each { |entry| selected_chip(entry) }
        end
        div(data: { person_picker_target: "ids" }, class: "hidden") do
          @selected.each do |entry|
            input(type: "hidden", name: @field_name, value: entry[:id], data: { person_id: entry[:id] })
          end
        end
      end
    end
  end

  private

  def search_input_id
    "#{@frame_id}-search"
  end

  def suggestions_block
    return if @suggestions.empty?

    div(class: "mt-3") do
      span(class: "block text-xs font-medium text-gray-600 dark:text-gray-300") { "Suggestions" }
      div(class: "mt-1 flex flex-wrap gap-2", data: { person_picker_target: "suggestions" }) do
        @suggestions.each do |suggestion|
          render Views::Shared::PersonPickerCandidate.new(
            person: suggestion[:person], subtitle: suggestion[:subtitle], compact: true
          )
        end
      end
    end
  end

  # Server-rendered version of the chip the Stimulus controller builds on
  # add — same structure so remove works identically on both.
  def selected_chip(entry)
    span(
      class: "inline-flex items-center gap-1 min-h-9 px-2.5 rounded-full bg-primary/10 text-primary-ink text-xs font-medium",
      data: { person_id: entry[:id] }
    ) do
      plain entry[:name]
      button(
        type: "button", aria: { label: "Remove #{entry[:name]}" },
        class: "leading-none text-primary-ink/80 hover:text-primary-ink cursor-pointer",
        data: { action: "person-picker#remove", person_picker_person_id_param: entry[:id] }
      ) { "×" }
    end
  end
end
