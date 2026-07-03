# frozen_string_literal: true

# Inline rename of a role (PATCH) and creation of a new role (POST) from the
# Framework Explorer's edit-mode role tree. Direct org-structure edits
# (shape-preserving, applied live) — not the suggested-edit path. Gated by
# FrameworkPolicy#update_role? / #add_role?. (Code/track edits are exposed via
# the Operation/MCP; the inline UI only renames for now.)
#
class Frameworks::RolesController < ApplicationController
  include Frameworks::RoleTreeFamiliesFrame

  before_action :set_framework
  before_action :set_role, only: [ :update ]

  # POST /frameworks/:framework_id/roles
  #
  # From the shared add-role modal (a family's "+ Add role" row). Re-renders
  # the `role-tree-families` frame so the new role appears under its family in
  # place, ghost-wiggled (no published levels yet), selection preserved.
  def create
    authorize @framework, :add_role?

    permitted = params.expect(role: [ :role_family_id, :name, :code, :track ])
    Operations::Frameworks::AddRole.call(
      context: pundit_user,
      params: { framework_id: @framework.framework_id, **permitted.to_h.symbolize_keys }
    )

    render_role_tree_families_frame(@framework)
  rescue Operations::Base::ParameterError
    head :unprocessable_content
  end

  # PATCH /frameworks/:framework_id/roles/:id
  def update
    authorize @framework, :update_role?

    Operations::Frameworks::UpdateRole.call(
      context: pundit_user,
      params: {
        framework_id: @framework.framework_id,
        role_id: @role.role_id,
        name: params.expect(role: [ :name ])[:name]
      }
    )

    render Views::Frameworks::Explorer::RoleNameFrame.new(
      role: @role.reload, framework_id: @framework.framework_id, mode: :edit
    ), layout: false
  rescue Operations::Base::ParameterError
    head :unprocessable_content
  end

  private

  def set_framework
    @framework = FrameworkState::Framework.find_by!(framework_id: params.expect(:framework_id))
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end

  # Scope the lookup to this framework (via its role families) so a role id from
  # another framework can't be targeted here.
  def set_role
    family_ids = FrameworkState::RoleFamily.where(framework_id: @framework.framework_id).select(:role_family_id)
    @role = FrameworkState::Role.find_by!(role_family_id: family_ids, role_id: params.expect(:id))
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end
end
