# frozen_string_literal: true

# "+ Add expectation" affordance for an empty-but-applicable matrix cell
# (edit mode, edit-structure holders only). Mirrors NewIllustrationFrame: a
# hover-revealed button that toggles to an inline textarea via the
# `inline-editor` Stimulus controller and POSTs to
# {Frameworks::ExpectationsController#create}.
#
# The form submits as a full Turbo Drive navigation (data-turbo-frame="_top")
# — authoring is shape-changing, so the controller redirects back to the edit
# page with the new cell rendered, matching the other structural adds.
class Views::Frameworks::Explorer::NewExpectationFrame < Views::Base
  # @param capability_id [String] UUID of the capability owning the cell
  # @param level_ordinal [Integer] the empty cell's level ordinal
  # @param framework_id [String] UUID of the framework (for the POST URL)
  def initialize(capability_id:, level_ordinal:, framework_id:)
    @capability_id = capability_id
    @level_ordinal = level_ordinal
    @framework_id = framework_id
  end

  def view_template
    div(class: "group/new-exp", data: { controller: "inline-editor" }) do
      add_button
      add_form
    end
  end

  private

  def add_button
    button(
      type: "button",
      class: "w-full text-xs text-gray-400 hover:text-primary flex items-center justify-center gap-1 " \
             "py-1.5 opacity-0 group-hover/new-exp:opacity-100 focus-visible:opacity-100 transition-opacity",
      data: { inline_editor_target: "display", action: "inline-editor#startEdit" }
    ) do
      svg(class: "w-3 h-3", fill: "none", viewBox: "0 0 24 24", stroke: "currentColor", stroke_width: "2") do |s|
        s.path(d: "M12 4v16m8-8H4")
      end
      plain "Add expectation"
    end
  end

  def add_form
    form(
      class: "hidden",
      method: "post",
      action: framework_expectations_path(framework_id: @framework_id),
      data: { inline_editor_target: "form", turbo_frame: "_top" }
    ) do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      input(type: "hidden", name: "behavioural_expectation[capability_id]", value: @capability_id)
      input(type: "hidden", name: "behavioural_expectation[level_ordinal]", value: @level_ordinal)

      textarea(
        class: "w-full text-xs border border-primary rounded px-2 py-1 " \
               "bg-white dark:bg-gray-900 text-gray-900 dark:text-white " \
               "resize-none focus:outline-none focus:ring-1 focus:ring-primary",
        rows: "3",
        name: "behavioural_expectation[description]",
        placeholder: "What does good look like at this level…",
        data: { inline_editor_target: "input" }
      ) { "" }

      div(class: "flex gap-1 mt-1") do
        button(
          type: "submit",
          class: "text-xs px-2 py-0.5 rounded bg-primary text-white hover:bg-primary/90"
        ) { "Add" }
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
