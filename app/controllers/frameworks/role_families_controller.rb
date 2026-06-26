# frozen_string_literal: true

# Direct edits of a role family from the Framework Explorer's edit-mode role
# tree — the inline name rename (in-place) and the full edit dialog (name +
# description + department). Org-structure edits are **direct** (shape-
# preserving, applied live) — unlike capability/category text, they do NOT
# route through the suggested-edit path, so there is no pending decoration or
# approval tier. Gated by FrameworkPolicy#update_role_family?.
#
# The dialog can change the department grouping, so its submit targets the
# `role-tree-families` Turbo Frame and we re-render the whole role tree (Turbo
# extracts that frame) — the family moves under its new department header, with
# the current role selection threaded back so checkboxes stay checked. The
# inline rename keeps targeting its own per-family name frame (in-place swap).
#
class Frameworks::RoleFamiliesController < ApplicationController
  FAMILIES_FRAME = "role-tree-families"

  before_action :set_framework
  before_action :set_role_family, only: [ :update ]

  # PATCH /frameworks/:framework_id/role_families/:id
  def update
    authorize @framework, :update_role_family?

    attrs = changed_role_family_attrs
    if attrs.present?
      Operations::Frameworks::UpdateRoleFamily.call(
        context: pundit_user,
        params: { framework_id: @framework.framework_id, role_family_id: @role_family.role_family_id, **attrs }
      )
    end

    if request.headers["Turbo-Frame"] == FAMILIES_FRAME
      render_families_frame
    else
      render Views::Frameworks::Explorer::RoleFamilyNameFrame.new(
        role_family: @role_family.reload, framework_id: @framework.framework_id, mode: :edit
      ), layout: false
    end
  rescue Operations::Base::ParameterError
    head :unprocessable_content
  end

  private

  # Only forward fields that actually changed, so a department-only move reads
  # as "Updated a role family's department" in the activity feed (not a verbose
  # name+description+department) and no redundant events are emitted. A blank
  # name IS forwarded so the operation rejects it (422 — a family can't be
  # renamed to nothing); a blank description/department is forwarded to clear it.
  def changed_role_family_attrs
    permitted = params.fetch(:role_family, {}).permit(:name, :description, :department)
    attrs = {}
    if permitted.key?(:name) && (permitted[:name].blank? || permitted[:name] != @role_family.name)
      attrs[:name] = permitted[:name]
    end
    if permitted.key?(:description) && permitted[:description].to_s != @role_family.description.to_s
      attrs[:description] = permitted[:description]
    end
    if permitted.key?(:department) && permitted[:department].to_s != @role_family.department.to_s
      attrs[:department] = permitted[:department]
    end
    attrs
  end

  # Re-render the role tree so Turbo swaps the `role-tree-families` frame — the
  # edited family re-groups under its (possibly new) department header. The
  # current role selection rides along in the form so it stays checked.
  def render_families_frame
    graph = Frameworks::ExplorerGraph.load(@framework.framework_id) ||
            Frameworks::ExplorerGraph.rebuild(@framework.framework_id)

    render Views::Frameworks::Explorer::RoleTree.new(
      role_families: graph.role_families,
      selected_role_ids: Array.wrap(params[:roles]).select(&:present?),
      track_filter: params[:track].presence || "both",
      framework_id: @framework.framework_id,
      mode: :edit,
      can_edit_structure: true
    ), layout: false
  end

  def set_framework
    @framework = FrameworkState::Framework.find_by!(framework_id: params.expect(:framework_id))
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end

  def set_role_family
    @role_family = FrameworkState::RoleFamily.find_by!(
      framework_id: @framework.framework_id, role_family_id: params.expect(:id)
    )
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end
end
