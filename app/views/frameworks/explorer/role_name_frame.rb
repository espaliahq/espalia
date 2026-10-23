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
  # @param error [String, nil] a rejected inline save (Hard-Won Lesson 26 — the
  #   422 must carry the frame, the message, and the attempted text)
  # @param attempted_value [String, nil] the value the rejected save carried
  def initialize(role:, framework_id:, mode: :view, error: nil, attempted_value: nil)
    @role = role
    @framework_id = framework_id
    @mode = mode
    @error = error
    @attempted_value = attempted_value
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

  # Never truncated — a role name the reader cannot finish is worse than a tall
  # row. `break-words` is the fallback for a genuinely long one; the row is
  # sized (pane width + a floating action cluster that reserves nothing) so
  # every name in a real framework fits on one line and the fallback is rare.
  def plain_name
    ghost = ghost_role?(@role)
    span(
      class: "text-sm text-muted break-words " \
             "#{suggestion_text_classes(added_in_draft: ghost)}",
      title: (ghost ? role_ghost_title : @role.name)
    ) { @role.name }
  end

  # The pencil is NOT rendered here — it lives in the row's floating action
  # cluster and names this frame with `data-editor-host-frame`. Inside the
  # frame it sat in the row's flow and reserved ~20 px of the name's width even
  # while invisible; outside it, it also survives this frame's PATCH re-render
  # for free.
  def editable
    div(class: "flex flex-col items-start gap-1 min-w-0", data: editor_data) do
      div(class: "min-w-0", data: { editor_display: true }) { plain_name }
      render_field_editor_error(@error)
    end
  end

  # Direct edit — no approval tier, so the editor always says "Save".
  def editor_data
    field_editor_data(
      action: framework_role_path(framework_id: @framework_id, id: @role.role_id),
      field: "role[name]",
      value: (@error ? @attempted_value : @role.name).to_s,
      label: "Role name",
      outcome: "apply",
      rows: 2,
      error: @error
    )
  end
end
