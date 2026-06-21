# frozen_string_literal: true

# Inline rename of a role from the Framework Explorer's edit-mode role tree.
# Direct org-structure edit (shape-preserving, applied live) — not the
# suggested-edit path. Gated by FrameworkPolicy#update_role?. (Code/track edits
# are exposed via the Operation/MCP; the inline UI only renames for now.)
#
class Frameworks::RolesController < ApplicationController
  before_action :set_framework
  before_action :set_role, only: [ :update ]

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
