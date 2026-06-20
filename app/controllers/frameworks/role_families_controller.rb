# frozen_string_literal: true

# Inline rename of a role family from the Framework Explorer's edit-mode role
# tree. Org-structure renames are **direct** (shape-preserving, applied live) —
# unlike capability/category text, they do NOT route through the suggested-edit
# path, so there is no pending decoration or approval tier. Gated by
# FrameworkPolicy#update_role_family?.
#
class Frameworks::RoleFamiliesController < ApplicationController
  before_action :set_framework

  # PATCH /frameworks/:framework_id/role_families/:id
  def update
    authorize @framework, :update_role_family?

    Operations::Frameworks::UpdateRoleFamily.call(
      context: pundit_user,
      params: {
        framework_id: @framework.framework_id,
        role_family_id: params.expect(:id),
        name: params.expect(role_family: [ :name ])[:name]
      }
    )

    render Views::Frameworks::Explorer::RoleFamilyNameFrame.new(
      role_family: role_family, framework_id: @framework.framework_id, mode: :edit
    ), layout: false
  rescue Operations::Base::ParameterError, RuntimeError
    head :unprocessable_content
  end

  private

  def set_framework
    @framework = FrameworkState::Framework.find_by!(framework_id: params.expect(:framework_id))
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end

  def role_family
    FrameworkState::RoleFamily.find_by!(
      framework_id: @framework.framework_id, role_family_id: params.expect(:id)
    )
  end
end
