# frozen_string_literal: true

# Renders a pending illustration suggestion as a ghost entry in the
# expanded row.
#
# Visually resembles an IllustrationFrame but with amber wavy underline
# decoration to signal its tentative status. The pencil icon allows:
# - Original author: amend the pending suggestion
# - Other collaborators: submit an alternative suggestion
#
class Views::Frameworks::Explorer::PendingIllustrationFrame < Views::Base
  include Views::Frameworks::Explorer::Concerns::SuggestionDecoration

  # @param suggestion [FrameworkState::SuggestedEdit] kind: "create", target: role_illustration
  # @param framework_id [String] UUID of the framework
  # @param is_author [Boolean] true if the current user authored this suggestion
  # @param error [String, nil] a failed inline-amend message, surfaced in the
  #   frame (a bodyless error response would blank the ghost to
  #   "Content missing")
  def initialize(suggestion:, framework_id:, is_author: false, error: nil)
    @suggestion = suggestion
    @framework_id = framework_id
    @is_author = is_author
    @error = error
    @attrs = (suggestion.proposed_attributes || {}).symbolize_keys
  end

  def view_template
    turbo_frame_tag("pending-suggestion-#{@suggestion.suggestion_id}") do
      li(
        class: "group/ill relative text-xs text-gray-600 dark:text-gray-400",
        data: { controller: "inline-editor" }
      ) do
        error_line if @error.present?
        display_mode
        edit_mode
      end
    end
  end

  private

  def error_line
    p(class: "pl-2 text-[11px] text-red-700 dark:text-red-400", role: "alert") do
      "Couldn\u2019t save: #{@error}"
    end
  end

  def display_mode
    decoration = suggestion_text_classes(pending_edit_count: 1)

    div(
      class: "flex items-start gap-1 pl-2",
      data: { inline_editor_target: "display" }
    ) do
      span(class: "flex-1 #{decoration}") { @attrs[:description] }
      edit_button
    end
  end

  def edit_button
    button(
      type: "button",
      class: "opacity-0 group-hover/ill:opacity-100 " \
             "group-focus-within/ill:opacity-100 focus-visible:opacity-100 " \
             "transition-opacity text-gray-400 hover:text-primary shrink-0 mt-0.5",
      data: { action: "inline-editor#startEdit" },
      aria_label: @is_author ? "Amend suggestion" : "Suggest alternative"
    ) do
      pencil_icon
    end
  end

  def edit_mode
    if @is_author
      amend_form
    else
      alternative_form
    end
  end

  # Author edits their pending suggestion via the amend endpoint.
  def amend_form
    form(
      class: "hidden pl-2",
      method: "post",
      action: amend_framework_suggestion_path(
        framework_id: @framework_id,
        id: @suggestion.suggestion_id
      ),
      data: {
        inline_editor_target: "form",
        turbo: "true",
        action: "turbo:submit-end->inline-editor#submitted"
      }
    ) do
      input(type: "hidden", name: "_method", value: "patch")
      # This form lives inside the ghost's Turbo Frame — flag the submission
      # so the amend endpoint re-renders this frame in place instead of its
      # detail-page redirect, which contains no matching frame and renders
      # as "Content missing" (Hard-Won Lesson 20: one endpoint, two
      # surfaces — branch on an explicit marker).
      input(type: "hidden", name: "inline", value: "1")
      # amend endpoint expects suggestion[suggested_value]
      # For create suggestions the amend updates proposed_attributes — the
      # controller maps suggested_value back to the description field.
      textarea_field("suggestion[suggested_value]", @attrs[:description])
      form_buttons("Save")
    end
  end

  # Other collaborators submit an alternative suggestion via the
  # illustrations create endpoint (which now routes through suggest_create).
  def alternative_form
    form(
      class: "hidden pl-2",
      method: "post",
      action: framework_illustrations_path(framework_id: @framework_id),
      data: {
        inline_editor_target: "form",
        turbo: "true",
        action: "turbo:submit-end->inline-editor#submitted"
      }
    ) do
      input(type: "hidden", name: "illustration[expectation_id]", value: @suggestion.parent_id)
      input(type: "hidden", name: "illustration[role_id]", value: @attrs[:role_id])
      textarea_field("illustration[description]", @attrs[:description])
      form_buttons("Suggest alternative")
    end
  end

  def textarea_field(name, value)
    textarea(
      class: "w-full text-xs border border-primary rounded px-2 py-1 " \
             "bg-white dark:bg-gray-900 text-gray-900 dark:text-white " \
             "resize-none focus:outline-none focus:ring-1 focus:ring-primary",
      rows: "3",
      name: name,
      data: { inline_editor_target: "input" }
    ) { value }
  end

  def form_buttons(submit_label)
    div(class: "flex gap-1 mt-1") do
      button(
        type: "submit",
        class: "text-xs px-2 py-0.5 rounded bg-primary text-white hover:bg-primary/90"
      ) { submit_label }
      button(
        type: "button",
        class: "text-xs px-2 py-0.5 rounded border border-gray-300 dark:border-gray-600 " \
               "text-gray-600 dark:text-gray-400 hover:bg-gray-100 dark:hover:bg-gray-800",
        data: { action: "inline-editor#cancel" }
      ) { "Cancel" }
    end
  end

  def pencil_icon
    svg(class: "w-3 h-3", fill: "none", viewBox: "0 0 24 24",
        stroke: "currentColor", stroke_width: "2") do |s|
      s.path(d: "M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5" \
                "m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z")
    end
  end
end
