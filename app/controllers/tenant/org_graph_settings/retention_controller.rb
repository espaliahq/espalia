# frozen_string_literal: true

# Saves how many years after someone leaves the Org Graph forgets them.
class Tenant::OrgGraphSettings::RetentionController < ApplicationController
  include OrgGraphSettingsRedirect

  # PATCH /tenant/org_graph/settings/retention
  def update
    authorize ActsAsTenant.current_tenant, :update_retention_period?, policy_class: TenantPolicy

    choice = params.expect(:retention).to_s
    op_params = choice == "never" ? { never: true } : { retention_years: choice.to_i }
    result = Operations::Tenants::UpdateRetentionPeriod.call(context: pundit_user, params: op_params)
    years = result[:retention_years]
    notice = years ? "Leavers are now forgotten #{years} #{'year'.pluralize(years)} after they leave." :
                     "Leavers are no longer forgotten."
    notice += " Scheduled forgetting is off until you check who is due and turn it on again." if result[:scheduled_forgetting_stopped]
    back_with_notice notice
  rescue Operations::Base::ParameterError => e
    back_with_refusal "The retention period could not be saved", e
  end
end
