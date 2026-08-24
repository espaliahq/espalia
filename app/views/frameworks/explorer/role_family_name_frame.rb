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

  def plain_name
    ghost = ghost_role_family?(@role_family)
    span(
      # line-clamp, not single-line truncate — same rationale as RoleNameFrame:
      # the narrow tree pane clipped real family names to a few characters.
      class: "text-sm font-medium text-gray-700 dark:text-gray-300 line-clamp-2 break-words " \
             "#{suggestion_text_classes(added_in_draft: ghost)}",
      title: (ghost ? role_family_ghost_title : @role_family.name)
    ) { @role_family.name }
  end

  def editable
    div(class: "group/ine flex items-start gap-1", data: { controller: "inline-editor" }) do
      div(class: "flex items-start gap-1 min-w-0", data: { inline_editor_target: "display" }) do
        plain_name
        render_inline_editor_pencil(aria_label: "Edit role family name")
      end
      render_inline_editor_form(
        action: framework_role_family_path(framework_id: @framework_id, id: @role_family.role_family_id),
        field_name: "role_family[name]",
        current_value: @role_family.name
      )
    end
  end
end
