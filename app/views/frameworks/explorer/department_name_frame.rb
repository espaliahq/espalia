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
    div(class: "group/ine flex flex-col #{HEADER_CLASSES}", data: editor_data) do
      div(class: "flex items-center gap-1 min-w-0", data: { editor_display: true }) do
        span(class: "truncate") { @department }
        render_inline_editor_pencil(aria_label: "Rename department")
      end
    end
  end

  # Direct edit (a bulk relabel across the group) — no approval tier, so "Save".
  # `normal-case` so the editor shows the stored value, not the uppercased
  # header; `tree-scope-fields` carries the current role selection into the
  # submit so the re-rendered tree keeps its checkboxes.
  def editor_data
    field_editor_data(
      action: framework_departments_path(@framework_id),
      field: "department[to]",
      value: @department.to_s,
      label: "Department name",
      outcome: "apply",
      rows: 1,
      turbo_frame: "role-tree-families",
      form_class: "normal-case",
      form_controller: "tree-scope-fields",
      extra: { "department[from]" => @department }
    )
  end
end
