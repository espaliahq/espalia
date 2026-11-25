# frozen_string_literal: true

# What changed in the tenant's pay bands, exchange rates or budget lines,
# newest first ([#539](https://github.com/espaliahq/espalia/issues/539)).
# Tenant admins only, as the tables are.
class Tenant::PlanningInputsHistoriesController < ApplicationController
  include PayBandsPage

  # GET /tenant/planning_inputs/:inputs/history
  def show
    authorize ActsAsTenant.current_tenant, Operations::Tenants::PlanningInputsHistory::POLICIES.fetch(params[:inputs]),
              policy_class: TenantPolicy
    read = Operations::Tenants::PlanningInputsHistory.call(context: pundit_user,
                                                           params: { inputs: params[:inputs], page: page })
    render Views::Tenant::PlanningInputsHistories::ShowView.new(read:, **admin_shell)
  end

  private

  def page = [ params[:page].to_i, 1 ].max
end
