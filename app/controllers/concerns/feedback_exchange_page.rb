# frozen_string_literal: true

# Renders the feedback exchange settings page, for the integrations show action
# and for a settings save that failed validation and must redisplay the form.
module FeedbackExchangePage
  extend ActiveSupport::Concern

  private

  # @return [Array<Tenant>] the tenants the signed-in user can switch to
  def tenants_for_user
    ActsAsTenant.without_tenant { current_user.tenants.to_a }
  end

  # @param errors [Array<String>] validation messages to show above the form
  # @param status [Symbol]
  def render_feedback_exchange_page(errors: [], status: :ok)
    tenant = ActsAsTenant.current_tenant

    render Views::Integrations::FeedbackExchangeView.new(
      config: tenant.feedback_exchange_config,
      secrets_present: tenant.feedback_exchange_secrets.presence,
      inbound_url: "#{request.base_url}/api/feedback_exchange",
      can_edit: policy(:integrations).update_feedback_exchange?,
      errors: errors,
      user: current_user,
      current_tenant: tenant,
      tenants: tenants_for_user
    ), status: status
  end
end
