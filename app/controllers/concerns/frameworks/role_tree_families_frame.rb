# frozen_string_literal: true

# Shared render of the explorer's `role-tree-families` Turbo Frame, used after a
# direct role-family / department edit that can change the department grouping.
# Re-rendering the whole role tree lets Turbo swap just that frame so the family
# (or every family in a renamed department) re-groups in place, while the current
# role selection is threaded back so checkboxes stay checked.
module Frameworks::RoleTreeFamiliesFrame
  extend ActiveSupport::Concern

  FAMILIES_FRAME = "role-tree-families"

  private

  def render_role_tree_families_frame(framework)
    graph = Frameworks::ExplorerGraph.load(framework.framework_id) ||
            Frameworks::ExplorerGraph.rebuild(framework.framework_id)

    render Views::Frameworks::Explorer::RoleTree.new(
      role_families: graph.role_families,
      selected_role_ids: Array.wrap(params[:roles]).select(&:present?),
      track_filter: params[:track].presence || "both",
      framework_id: framework.framework_id,
      mode: :edit,
      can_edit_structure: true
    ), layout: false
  end
end
