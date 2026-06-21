# frozen_string_literal: true

# Turbo Frame wrapping a role's name + inline-edit affordance in the explorer's
# left role-tree pane. Rendered in-place (by {Views::Frameworks::Explorer::RoleTree})
# and as the PATCH response from {Frameworks::RolesController#update}.
#
# Org-structure renames are direct (not the suggested-edit path) — no
# pending-suggestion decoration. Display mode shows the plain name; :edit adds a
# hover pencil + inline form. (Code/track edits are exposed via the
# Operation/MCP; no inline UI field yet.)
#
class Views::Frameworks::Explorer::RoleNameFrame < Views::Base
  include Phlex::Rails::Helpers::TurboFrameTag
  include Views::Frameworks::Explorer::Concerns::InlineEditable

  # @param role [FrameworkState::Role, Frameworks::ExplorerGraph::Role]
  # @param framework_id [String]
  # @param mode [Symbol] :view or :edit
  def initialize(role:, framework_id:, mode: :view)
    @role = role
    @framework_id = framework_id
    @mode = mode
  end

  def view_template
    turbo_frame_tag("role-name-#{@role.role_id}", class: "flex-1 min-w-0") do
      if @mode == :edit
        editable
      else
        plain_name
      end
    end
  end

  private

  def plain_name
    span(class: "text-sm text-gray-600 dark:text-gray-400 truncate") { @role.name }
  end

  def editable
    div(class: "group/ine flex items-start gap-1", data: { controller: "inline-editor" }) do
      div(class: "flex items-start gap-1 min-w-0", data: { inline_editor_target: "display" }) do
        plain_name
        render_inline_editor_pencil(aria_label: "Edit role name")
      end
      render_inline_editor_form(
        action: framework_role_path(framework_id: @framework_id, id: @role.role_id),
        field_name: "role[name]",
        current_value: @role.name
      )
    end
  end
end
