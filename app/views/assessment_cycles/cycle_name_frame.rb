# frozen_string_literal: true

# Inline-editable cycle name. Rendered both inside the show view's header
# (for the initial page render) and as the PATCH response from
# {AssessmentCyclesController#rename}, so Turbo swaps the frame in place
# after a successful edit.
#
# In display mode the heading shows the cycle name. When `is_admin` is true
# and the cycle is open, hovering reveals a pencil that switches to a small
# inline form. Submitting PATCHes to the rename endpoint and the rendered
# response carries the updated name back into this same frame.
#
class Views::AssessmentCycles::CycleNameFrame < Views::Base
  include Phlex::Rails::Helpers::TurboFrameTag

  # @param cycle [AssessmentCycle]
  # @param is_admin [Boolean]
  def initialize(cycle:, is_admin:)
    @cycle = cycle
    @is_admin = is_admin
  end

  def view_template
    turbo_frame_tag("cycle-name-#{@cycle.cycle_id}") do
      if editable?
        editable
      else
        display_heading
      end
    end
  end

  private

  def editable?
    @is_admin && @cycle.open?
  end

  def display_heading
    h1(class: "text-2xl font-bold text-gray-900 dark:text-white") { @cycle.name }
  end

  def editable
    div(class: "group/ine inline-flex items-start gap-2",
        data: { controller: "inline-editor" }) do
      div(class: "flex items-start gap-2",
          data: { inline_editor_target: "display" }) do
        display_heading
        pencil
      end
      edit_form
    end
  end

  def pencil
    button(
      type: "button",
      class: "opacity-0 group-hover/ine:opacity-100 group-focus-within/ine:opacity-100 " \
             "focus-visible:opacity-100 transition-opacity text-gray-400 hover:text-primary " \
             "shrink-0 mt-1",
      data: { action: "inline-editor#startEdit" },
      aria_label: "Edit cycle name"
    ) do
      svg(class: "w-4 h-4", fill: "none", viewBox: "0 0 24 24",
          stroke: "currentColor", stroke_width: "2") do |s|
        s.path(d: "M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5" \
                  "m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z")
      end
    end
  end

  def edit_form
    form(
      class: "hidden",
      method: "post",
      action: rename_assessment_cycle_path(@cycle),
      data: { inline_editor_target: "form", turbo: "true" }
    ) do
      input(type: "hidden", name: "_method", value: "patch")
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      input(
        type: "text",
        name: "assessment_cycle[name]",
        value: @cycle.name,
        required: true,
        class: "w-72 text-lg font-semibold border border-primary rounded-sm px-2 py-1 " \
               "bg-white dark:bg-gray-900 text-gray-900 dark:text-white " \
               "focus:outline-none focus:ring-1 focus:ring-primary",
        data: { inline_editor_target: "input" }
      )
      div(class: "flex gap-1 mt-1") do
        button(
          type: "submit",
          class: "text-xs px-2 py-0.5 rounded-sm bg-primary text-white hover:bg-primary/90"
        ) { "Save" }
        button(
          type: "button",
          class: "text-xs px-2 py-0.5 rounded-sm border border-gray-300 dark:border-gray-600 " \
                 "text-gray-600 dark:text-gray-400 hover:bg-gray-100 dark:hover:bg-gray-800",
          data: { action: "inline-editor#cancel" }
        ) { "Cancel" }
      end
    end
  end
end
