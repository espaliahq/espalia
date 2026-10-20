# frozen_string_literal: true

# Renders the AI model settings page, for the integrations show action and for
# a settings save that failed validation and must redisplay the form.
module AiModelPage
  extend ActiveSupport::Concern

  private

  # @return [Array<Tenant>] the tenants the signed-in user can switch to
  def tenants_for_user
    ActsAsTenant.without_tenant { current_user.tenants.to_a }
  end

  # Status always shows what is saved. After a rejected save the form keeps what
  # the admin typed, but the connection card and the key badge must not claim
  # values that were never stored.
  #
  # @param errors [Array<String>] validation messages to show above the form
  # @param status [Symbol]
  def render_ai_model_page(errors: [], status: :ok)
    tenant = ActsAsTenant.current_tenant
    saved = errors.empty? ? tenant : Tenant.find(tenant.id)

    render Views::Integrations::AiModelView.new(
      config: saved.effective_ai_config,
      form_config: errors.empty? ? tenant.effective_ai_config : tenant.ai_config,
      state: saved.effective_ai_config.state(saved),
      key_stored: saved.ai_api_key.present?,
      can_edit: policy(:integrations).update_ai_model?,
      errors: errors,
      user: current_user,
      current_tenant: tenant,
      tenants: tenants_for_user
    ), status: status
  end
end
