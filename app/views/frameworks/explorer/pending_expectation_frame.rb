# frozen_string_literal: true

# Renders a pending behavioural-expectation creation suggestion as an editable
# ghost in an otherwise-empty matrix cell — so a proposed expectation is visible
# in the grid (not just the feed) and follows the same inline-edit pattern as
# every other suggestion. The amber wavy underline is the explorer's pending
# signal; a hover-revealed pencil opens an inline form pre-filled with the
# current value.
#
# Both author and non-author submit to the same create endpoint
# (ExpectationsController#create → SetBehaviouralExpectation): the author's
# resubmit *amends* their pending proposal (amend-on-duplicate), a non-author's
# becomes their own alternative proposal. So the cell never shows a separate
# "+ Add expectation" affordance while a proposal exists.
class Views::Frameworks::Explorer::PendingExpectationFrame < Views::Base
  include Views::Frameworks::Explorer::Concerns::SuggestionDecoration

  # @param suggestion [FrameworkState::SuggestedEdit] kind: "create", target: behavioural_expectation
  # @param framework_id [String]
  # @param level_ordinal [Integer] the cell's level ordinal
  # @param is_author [Boolean] whether the viewer authored this proposal
  def initialize(suggestion:, framework_id:, level_ordinal:, is_author: false)
    @suggestion = suggestion
    @framework_id = framework_id
    @level_ordinal = level_ordinal
    @is_author = is_author
    @attrs = (suggestion.proposed_attributes || {}).symbolize_keys
  end

  def view_template
    div(class: "group/pe relative mb-1", data: { controller: "inline-editor" }) do
      display
      edit_form
    end
  end

  private

  # An amended create carries its current value in suggested_value (the amend
  # only updates that field); fall back to the original proposed description.
  def proposed_text
    @suggestion.suggested_value.presence || @attrs[:description]
  end

  def display
    div(class: "flex items-start gap-1", data: { inline_editor_target: "display" }) do
      span(class: "flex-1 text-sm #{suggestion_text_classes(pending_edit_count: 1)}") { proposed_text }
      pencil_button
    end
  end

  def pencil_button
    button(
      type: "button",
      class: "opacity-0 group-hover/pe:opacity-100 group-focus-within/pe:opacity-100 " \
             "focus-visible:opacity-100 transition-opacity text-gray-400 hover:text-primary shrink-0 mt-0.5",
      data: { action: "inline-editor#startEdit" },
      aria_label: @is_author ? "Amend suggestion" : "Suggest alternative"
    ) do
      svg(class: "w-3 h-3", fill: "none", viewBox: "0 0 24 24", stroke: "currentColor", stroke_width: "2") do |s|
        s.path(d: "M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5" \
                  "m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z")
      end
    end
  end

  # Submits to the create endpoint; SetBehaviouralExpectation amends the author's
  # own pending proposal or records a non-author's alternative. Redirects (full
  # navigation) like the "+ Add expectation" form, so data-turbo-frame="_top".
  def edit_form
    form(
      class: "hidden mt-1",
      method: "post",
      action: framework_expectations_path(framework_id: @framework_id),
      data: { inline_editor_target: "form", turbo_frame: "_top" }
    ) do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      input(type: "hidden", name: "behavioural_expectation[capability_id]", value: @suggestion.parent_id)
      input(type: "hidden", name: "behavioural_expectation[level_ordinal]", value: @level_ordinal)

      textarea(
        class: "w-full text-xs border border-primary rounded px-2 py-1 " \
               "bg-white dark:bg-gray-900 text-gray-900 dark:text-white " \
               "resize-none focus:outline-none focus:ring-1 focus:ring-primary",
        rows: "3",
        name: "behavioural_expectation[description]",
        data: { inline_editor_target: "input" }
      ) { proposed_text }

      div(class: "flex gap-1 mt-1") do
        button(
          type: "submit",
          class: "text-xs px-2 py-0.5 rounded bg-primary text-white hover:bg-primary/90"
        ) { @is_author ? "Save" : "Suggest alternative" }
        button(
          type: "button",
          class: "text-xs px-2 py-0.5 rounded border border-gray-300 dark:border-gray-600 " \
                 "text-gray-600 dark:text-gray-400 hover:bg-gray-100 dark:hover:bg-gray-800",
          data: { action: "inline-editor#cancel" }
        ) { "Cancel" }
      end
    end
  end
end
