# frozen_string_literal: true

# The department group header in the explorer's role tree. In edit mode (for an
# edit-structure holder) it's inline-editable: editing the label renames the
# department across *every* role family currently in the group at once (a
# department is a free-text grouping label, not an entity).
#
# Direct edit — no suggested-edit path, no pending decoration. Submits to
# {Frameworks::DepartmentsController#update}, targeting the `role-tree-families`
# Turbo Frame so the families re-group under the renamed header in place; the
# `tree-scope-fields` controller carries the current role selection so checkboxes
# stay checked. The shared `inline-editor` controller drives the display/form
# toggle and the hover pencil.
class Views::Frameworks::Explorer::DepartmentNameFrame < Views::Base
  include Views::Frameworks::Explorer::Concerns::InlineEditable

  HEADER_CLASSES = "px-3 py-1.5 text-xs font-bold text-gray-600 dark:text-gray-300 " \
                   "uppercase tracking-wider"

  # @param department [String] the department label (a non-blank group header)
  # @param framework_id [String]
  # @param mode [Symbol] :view, or :edit to render the inline rename affordance
  def initialize(department:, framework_id:, mode: :view)
    @department = department
    @framework_id = framework_id
    @mode = mode
  end

  def view_template
    if @mode == :edit
      editable
    else
      plain_header
    end
  end

  private

  def plain_header
    div(class: HEADER_CLASSES) { @department }
  end

  def editable
    div(class: "group/ine flex items-center gap-1 #{HEADER_CLASSES}",
        data: { controller: "inline-editor" }) do
      div(class: "flex items-center gap-1 min-w-0", data: { inline_editor_target: "display" }) do
        span(class: "truncate") { @department }
        render_inline_editor_pencil(aria_label: "Rename department")
      end
      rename_form
    end
  end

  def rename_form
    form(
      # `normal-case` so the input shows the stored value, not the uppercased
      # header. Targets the families frame so the whole group re-renders.
      class: "hidden w-56 max-w-[85vw] normal-case",
      method: "post",
      action: framework_departments_path(@framework_id),
      data: {
        controller: "tree-scope-fields",
        inline_editor_target: "form",
        turbo: "true",
        turbo_frame: "role-tree-families",
        action: "turbo:submit-end->inline-editor#submitted"
      }
    ) do
      input(type: "hidden", name: "_method", value: "patch")
      input(type: "hidden", name: "department[from]", value: @department)
      input(
        type: "text", name: "department[to]", value: @department,
        class: "w-full text-sm border border-primary rounded px-2 py-1 " \
               "bg-white dark:bg-gray-900 text-gray-900 dark:text-white " \
               "focus:outline-none focus:ring-1 focus:ring-primary",
        data: { inline_editor_target: "input" }
      )
      div(class: "flex gap-1 mt-1") do
        button(
          type: "submit",
          class: "text-xs px-2 py-0.5 rounded bg-primary text-white hover:bg-primary/90"
        ) { "Save" }
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
