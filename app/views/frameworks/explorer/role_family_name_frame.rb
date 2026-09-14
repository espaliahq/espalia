# frozen_string_literal: true

# Turbo Frame wrapping a role family's name + inline-edit affordance in the
# explorer's left role-tree pane. Rendered in-place (by
# {Views::Frameworks::Explorer::RoleTree}) and as the PATCH response from
# {Frameworks::RoleFamiliesController#update} so Turbo swaps the name in place.
#
# Org-structure renames are direct (not the suggested-edit path) — there is no
# pending-suggestion decoration here. Display mode shows the plain name;
# :edit adds a hover pencil + inline form.
#
# A **ghost** family (no role with published levels — hidden from the view-mode
# tree) wears the wiggle on its name, self-computed so PATCH re-renders stay
# decorated without threading a flag.
#
class Views::Frameworks::Explorer::RoleFamilyNameFrame < Views::Base
  include Phlex::Rails::Helpers::TurboFrameTag
  include Views::Frameworks::Explorer::Concerns::HoverCluster
  include Views::Frameworks::Explorer::Concerns::InlineEditable
  include Views::Frameworks::Explorer::Concerns::SuggestionDecoration
  include Views::Frameworks::Explorer::Concerns::GhostEntities

  # @param role_family [FrameworkState::RoleFamily, Frameworks::ExplorerGraph::RoleFamily]
  # @param framework_id [String]
  # @param mode [Symbol] :view or :edit
  def initialize(role_family:, framework_id:, mode: :view)
    @role_family = role_family
    @framework_id = framework_id
    @mode = mode
  end

  def view_template
    turbo_frame_tag("role-family-name-#{@role_family.role_family_id}", class: "flex-1 min-w-0") do
      if @mode == :edit
        editable
      else
        plain_name
      end
    end
  end

  private

  # Never truncated — same rule as RoleNameFrame: `break-words` is the fallback
  # for a genuinely long name, and the row is sized so it is rarely reached.
  def plain_name
    ghost = ghost_role_family?(@role_family)
    span(
      class: "text-sm font-medium text-gray-700 dark:text-gray-300 break-words " \
             "#{suggestion_text_classes(added_in_draft: ghost)}",
      title: (ghost ? role_family_ghost_title : @role_family.name)
    ) { @role_family.name }
  end

  # The pencil lives in the row's floating action cluster, not here — see
  # RoleNameFrame#editable for why.
  def editable
    div(class: "flex flex-col items-start gap-1 min-w-0", data: editor_data) do
      div(class: "min-w-0", data: { editor_display: true }) { plain_name }
    end
  end

  # Org-structure renames are direct edits with no approval tier, so the editor
  # always says "Save" — never "Propose".
  def editor_data
    field_editor_data(
      action: framework_role_family_path(framework_id: @framework_id, id: @role_family.role_family_id),
      field: "role_family[name]",
      value: @role_family.name.to_s,
      label: "Role family name",
      outcome: "apply",
      rows: 2
    )
  end
end
