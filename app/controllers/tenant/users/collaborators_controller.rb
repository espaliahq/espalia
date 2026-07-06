# frozen_string_literal: true

# Manages a tenant user's framework collaborator assignments from the
# tenant user detail screen.
#
# Accepts framework + role + optional scope and dispatches the shared
# Operations::Frameworks::{AddCollaborator,RemoveCollaborator} (the same
# implementation the MCP tools use). Authorization is delegated to
# TenantUserPolicy#manage_collaborators? (tenant admins only) here, with
# the Operations' own FrameworkPolicy check as the second layer.
#
class Tenant::Users::CollaboratorsController < ApplicationController
  before_action :set_tenant_user

  # POST /tenant/users/:user_id/collaborators
  def create
    authorize @tenant_user, :manage_collaborators?
    person = @tenant_user.ensure_person!
    p = params.expect(collaborator: [ :framework_id, :role, :scope_type, :scope_id ])

    Operations::Frameworks::AddCollaborator.call(
      context: pundit_user,
      params: {
        framework_id: p[:framework_id],
        person_id: person.id,
        role: p[:role],
        scope_type: p[:scope_type].presence,
        scope_id: p[:scope_id].presence
      }
    )
    redirect_to tenant_user_path(@tenant_user), notice: "Collaborator added."
  rescue ActiveRecord::RecordNotFound
    # AR's default message leaks model/schema detail — keep the flash generic.
    redirect_to tenant_user_path(@tenant_user), alert: "Framework or scope not found."
  rescue Operations::Base::ParameterError, RuntimeError => e
    redirect_to tenant_user_path(@tenant_user), alert: e.message
  end

  # DELETE /tenant/users/:user_id/collaborators/:id
  # `id` is a composite "framework_id:role:scope_type:scope_id" where the
  # latter two may be empty.
  def destroy
    authorize @tenant_user, :manage_collaborators?
    person = @tenant_user.ensure_person!
    fw_id, role, scope_type, scope_id = params.expect(:id).split(":", 4)

    Operations::Frameworks::RemoveCollaborator.call(
      context: pundit_user,
      params: {
        framework_id: fw_id,
        person_id: person.id,
        role: role,
        scope_type: scope_type.presence,
        scope_id: scope_id.presence
      }
    )
    redirect_to tenant_user_path(@tenant_user), notice: "Collaborator removed."
  rescue ActiveRecord::RecordNotFound
    redirect_to tenant_user_path(@tenant_user), alert: "Framework or scope not found."
  rescue Operations::Base::ParameterError, RuntimeError => e
    redirect_to tenant_user_path(@tenant_user), alert: e.message
  end

  private

  def set_tenant_user
    @tenant_user = TenantUser.find(params.expect(:user_id))
  rescue ActiveRecord::RecordNotFound
    redirect_to tenant_users_path
  end
end
