# frozen_string_literal: true

# Turns scheduled forgetting on, for the count the admin saw, and off.
class Tenant::OrgGraphSettings::ForgettingSchedulesController < ApplicationController
  include OrgGraphSettingsRedirect

  # POST /tenant/org_graph/settings/forgetting_schedule
  def create
    authorize ActsAsTenant.current_tenant, :forget_person?, policy_class: TenantPolicy

    Operations::Tenants::EnableScheduledForgetting.call(
      context: pundit_user, params: { confirm_count: params.expect(:confirm_count).to_i }
    )
    back_with_notice "Scheduled forgetting is on."
  rescue Operations::Base::ParameterError => e
    back_with_refusal "Scheduled forgetting was not turned on", e
  end

  # DELETE /tenant/org_graph/settings/forgetting_schedule
  def destroy
    authorize ActsAsTenant.current_tenant, :forget_person?, policy_class: TenantPolicy

    Operations::Tenants::DisableScheduledForgetting.call(context: pundit_user, params: {})
    back_with_notice "Scheduled forgetting is off. Anyone already forgotten stays forgotten."
  end
end
