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

  # Status always shows what is saved. After a rejected save the form keeps what
  # the admin typed, but the connection card and the secret badges must not claim
  # values that were never stored.
  #
  # @param errors [Array<String>] validation messages to show above the form
  # @param status [Symbol]
  def render_feedback_exchange_page(errors: [], status: :ok)
    tenant = ActsAsTenant.current_tenant
    saved = errors.empty? ? tenant : Tenant.find(tenant.id)

    render Views::Integrations::FeedbackExchangeView.new(
      config: saved.feedback_exchange_config,
      form_config: tenant.feedback_exchange_config,
      secrets_present: saved.feedback_exchange_secrets.presence,
      inbound_url: "#{request.base_url}/api/feedback_exchange",
      can_edit: policy(:integrations).update_feedback_exchange?,
      errors: errors,
      user: current_user,
      current_tenant: tenant,
      tenants: tenants_for_user
    ), status: status
  end
end
