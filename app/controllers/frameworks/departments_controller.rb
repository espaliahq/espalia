# frozen_string_literal: true

# Bulk rename of a department grouping from the Framework Explorer's edit-mode
# role tree — editing a department header relabels every role family currently
# in that group at once. A department is a free-text label (not an entity), so
# this dispatches the shared Operations::Frameworks::RenameDepartment, which
# fans out to UpdateRoleFamily per affected family. Direct, shape-preserving,
# applied live; gated by FrameworkPolicy#update_role_family?.
#
# Like the per-family edit, the submit targets the `role-tree-families` Turbo
# Frame so the families re-group under the renamed header in place, with the
# current role selection threaded back.
class Frameworks::DepartmentsController < ApplicationController
  include Frameworks::RoleTreeFamiliesFrame

  before_action :set_framework

  # PATCH /frameworks/:framework_id/departments
  def update
    authorize @framework, :update_role_family?

    # Saving the editor unchanged is a no-op, not a refusal: the Operation
    # rejects it, and a bodyless 422 would leave the editor open and silent.
    unless department_params[:to].to_s == department_params[:from]
      Operations::Frameworks::RenameDepartment.call(
        context: pundit_user,
        params: {
          framework_id: @framework.framework_id,
          from: department_params[:from],
          to: department_params[:to]
        }
      )
    end

    render_role_tree_families_frame(@framework)
  rescue Operations::Base::ParameterError
    head :unprocessable_content
  end

  private

  def department_params
    params.expect(department: [ :from, :to ])
  end

  def set_framework
    @framework = FrameworkState::Framework.find_by!(framework_id: params.expect(:framework_id))
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end
end
