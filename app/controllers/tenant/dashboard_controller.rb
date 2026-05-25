# frozen_string_literal: true

# Landing page for the tenant administration surface. Renders a small
# overview with cards linking to each admin section (Theme, Users,
# Integrations). Gated by TenantPolicy — tenant admins + global admins
# only.
#
class Tenant::DashboardController < ApplicationController
  # GET /tenant
  def show
    authorize ActsAsTenant.current_tenant, :show?, policy_class: TenantPolicy
    render Views::Tenant::Dashboard::ShowView.new(
      user: current_user,
      current_tenant: ActsAsTenant.current_tenant,
      tenants: tenants_for_user
    )
  end

  private

  # @return [Array<Tenant>]
  def tenants_for_user
    ActsAsTenant.without_tenant { current_user.tenants.to_a }
  end
end
