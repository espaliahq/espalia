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
# A **ghost** role (no published levels — hidden from the view-mode tree) wears
# the wiggle on its name, self-computed from the role so the controllers' PATCH
# re-renders stay decorated without threading a flag.
#
class Views::Frameworks::Explorer::RoleNameFrame < Views::Base
  include Phlex::Rails::Helpers::TurboFrameTag
  include Views::Frameworks::Explorer::Concerns::HoverCluster
  include Views::Frameworks::Explorer::Concerns::InlineEditable
  include Views::Frameworks::Explorer::Concerns::SuggestionDecoration
  include Views::Frameworks::Explorer::Concerns::GhostEntities

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
    ghost = ghost_role?(@role)
    span(
      # line-clamp, never single-line truncate: after the checkbox + reserved
      # hover controls the name gets ~100px in the w-72 pane, so `truncate`
      # clipped most real role names to a few characters. Two lines fit any
      # sane name; the tooltip is the recovery beyond that.
      class: "text-sm text-gray-600 dark:text-gray-400 line-clamp-2 break-words " \
             "#{suggestion_text_classes(added_in_draft: ghost)}",
      title: (ghost ? role_ghost_title : @role.name)
    ) { @role.name }
  end

  def editable
    div(class: "flex flex-col items-start gap-1", data: editor_data) do
      div(class: "flex items-start gap-1 min-w-0", data: { editor_display: true }) do
        plain_name
        render_inline_editor_pencil(aria_label: "Edit role name", scope: "tree")
      end
    end
  end

  # Direct edit — no approval tier, so the editor always says "Save".
  def editor_data
    field_editor_data(
      action: framework_role_path(framework_id: @framework_id, id: @role.role_id),
      field: "role[name]",
      value: @role.name.to_s,
      label: "Role name",
      outcome: "apply",
      rows: 2
    )
  end
end
