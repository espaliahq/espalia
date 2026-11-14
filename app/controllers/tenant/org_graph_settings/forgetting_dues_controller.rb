# frozen_string_literal: true

# The forgetting panel's lazy count of leavers due today. Erases nothing.
class Tenant::OrgGraphSettings::ForgettingDuesController < ApplicationController
  # GET /tenant/org_graph/settings/forgetting_due
  def show
    authorize ActsAsTenant.current_tenant, :forget_person?, policy_class: TenantPolicy

    render Views::Tenant::OrgGraph::Settings::ForgettingDueFrame.new(**due)
  end

  private

  # @return [Hash] `count:` or `problem:` for the frame
  def due
    { count: Operations::Tenants::ForgettingDryRun.call(context: pundit_user, params: {})[:count] }
  rescue Operations::Base::ParameterError
    { problem: "Forgetting isn't set up on this server, so nobody can be counted." }
  rescue StandardError => e
    Rails.error.report(e, handled: true, context: { tenant_id: ActsAsTenant.current_tenant&.id })
    { problem: "The HRIS couldn't be asked who is still employed. Try again in a minute." }
  end
end
