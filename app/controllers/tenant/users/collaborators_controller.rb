# frozen_string_literal: true

# Manages a tenant user's framework collaborator assignments from the
# tenant user detail screen.
#
# Accepts framework + role + optional scope and dispatches the matching
# RES command via Frameworks::CommandHandler. Authorization is delegated
# to TenantUserPolicy#manage_collaborators? (tenant admins only).
#
class Tenant::Users::CollaboratorsController < ApplicationController
  before_action :set_tenant_user

  # POST /tenant/users/:user_id/collaborators
  def create
    authorize @tenant_user, :manage_collaborators?
    person = @tenant_user.ensure_person!
    p = params.expect(collaborator: [ :framework_id, :role, :scope_type, :scope_id ])

    Frameworks::CommandHandler.new.add_collaborator(
      p[:framework_id], person.id, p[:role],
      scope_type: p[:scope_type].presence,
      scope_id:   p[:scope_id].presence,
      added_by:   current_person&.id
    )
    redirect_to tenant_user_path(@tenant_user.id), notice: "Collaborator added."
  rescue RuntimeError => e
    redirect_to tenant_user_path(@tenant_user.id), alert: e.message
  end

  # DELETE /tenant/users/:user_id/collaborators/:id
  # `id` is a composite "framework_id:role:scope_type:scope_id" where the
  # latter two may be empty.
  def destroy
    authorize @tenant_user, :manage_collaborators?
    person = @tenant_user.ensure_person!
    fw_id, role, scope_type, scope_id = params.expect(:id).split(":", 4)

    Frameworks::CommandHandler.new.remove_collaborator(
      fw_id, person.id, role,
      scope_type: scope_type.presence,
      scope_id:   scope_id.presence,
      removed_by: current_person&.id
    )
    redirect_to tenant_user_path(@tenant_user.id), notice: "Collaborator removed."
  rescue RuntimeError => e
    redirect_to tenant_user_path(@tenant_user.id), alert: e.message
  end

  private

  def set_tenant_user
    @tenant_user = TenantUser.find_by!(id: params.expect(:user_id))
  rescue ActiveRecord::RecordNotFound
    redirect_to tenant_users_path
  end
end
