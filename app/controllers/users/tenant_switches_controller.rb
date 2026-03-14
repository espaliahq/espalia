# frozen_string_literal: true

# Handles switching the active tenant for a multi-tenant user.
#
# Stores the chosen tenant ID in the session. Only tenants the current user
# belongs to may be selected.
class Users::TenantSwitchesController < ApplicationController
  # GET /users/tenant_switch/new
  def new
    @tenants = current_user.tenants
  end

  # POST /users/tenant_switch
  def create
    tenant = current_user.tenants.find(params[:tenant_id])
    session[:current_tenant_id] = tenant.id
    redirect_to root_path, status: :see_other
  rescue ActiveRecord::RecordNotFound
    redirect_to new_users_tenant_switch_path, status: :see_other
  end
end
