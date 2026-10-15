# frozen_string_literal: true

# The first step of "Give feedback": who is it for? Rendered into the
# `#evidence-modal` frame for `mode=give`. A debounced search over the
# recipient directory ({Assessments::FeedbackRecipients}) plus the giver's org
# neighbours as suggestions; picking a row navigates the same frame to the
# `:new` form for that person's assignment, so the modal never closes between
# the two steps.
#
# Reuses the `person-picker` controller for the typeahead only: its `search`
# repoints the results frame, and the rows are links rather than `add`
# buttons, so no selection state is kept client-side.
class Views::Evidence::RecipientPickerForm < Views::Base
  FRAME_ID = "evidence-recipients"
  INPUT = "mt-1 block w-full rounded-md border border-gray-300 dark:border-gray-600 " \
          "bg-white dark:bg-gray-900 px-3 py-2 text-sm text-gray-900 dark:text-white"

  # @param suggestions [Array<Assessments::FeedbackRecipients::Recipient>]
  # @param candidates_url [String] the typeahead endpoint (renders {RecipientCandidatesFrame})
  # @param return_to [String] "hub" — threaded into the `:new` form's submit
  def initialize(suggestions:, candidates_url:, return_to:)
    @suggestions = suggestions
    @candidates_url = candidates_url
    @return_to = return_to
  end

  def view_template
    turbo_frame_tag("evidence-modal") do
      div(class: "p-5",
          data: { controller: "person-picker", person_picker_candidates_url_value: @candidates_url,
                  person_picker_frame_id_value: FRAME_ID, person_picker_field_name_value: "recipient" }) do
        header
        p(class: "text-sm text-gray-600 dark:text-gray-300 mb-3") do
          "Anyone with a framework assignment. You can place the feedback on a capability yourself, " \
            "or leave that to them and their manager."
        end
        label(for: "give-feedback-search", class: "block text-sm font-medium text-gray-900 dark:text-white") { "Who is it for?" }
        div(class: "relative") do
          input(id: "give-feedback-search", type: "search", placeholder: "Search by name or email…", class: INPUT,
                autofocus: true, data: { person_picker_target: "search", action: "input->person-picker#search" })
          div(class: "absolute left-0 right-0 top-full mt-1 z-20") do
            render Views::Evidence::RecipientCandidatesFrame.new(entries: [], query: nil, return_to: @return_to)
          end
        end
        suggestions_block
      end
    end
  end

  private

  def header
    div(class: "flex items-center justify-between mb-3") do
      h2(class: "text-base font-semibold text-gray-900 dark:text-white") { "Give feedback" }
      button(type: "button", aria: { label: "Close" }, data: { action: "modal#close" },
             class: "h-9 w-9 inline-flex items-center justify-center rounded-md text-gray-500 hover:text-gray-800 dark:hover:text-gray-200") { "×" }
    end
  end

  def suggestions_block
    return if @suggestions.empty?

    div(class: "mt-4") do
      span(class: "block text-xs font-semibold uppercase tracking-wide text-gray-600 dark:text-gray-300") { "People you work with" }
      div(class: "mt-1 divide-y divide-gray-100 dark:divide-gray-800") do
        @suggestions.each { |recipient| render Views::Evidence::RecipientRow.new(recipient: recipient, return_to: @return_to) }
      end
    end
  end
end
