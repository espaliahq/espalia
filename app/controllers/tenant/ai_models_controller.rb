# frozen_string_literal: true

# Settings for the model behind AI features, and the connection test.
#
# The page itself is {Tenant::IntegrationsController#show} (id "ai-model").
# Writes are web-only on purpose: this is a single tenant-admin page holding an
# API key, which must never travel through an MCP client. The MCP surface is
# the read-only `integrations_ai_model_status`.
class Tenant::AiModelsController < ApplicationController
  include AiModelPage

  REPLY_LIMIT = 120

  # PATCH /tenant/integrations/ai-model
  def update
    authorize :integrations, :update_ai_model?

    key = params.dig(:ai_model, :api_key)
    current_tenant.update_ai_model!(settings: settings_params, api_key: key.is_a?(String) ? key : nil)
    redirect_to tenant_integration_path("ai-model"), notice: "AI model settings saved.", status: :see_other
  rescue ActiveRecord::RecordInvalid => e
    render_ai_model_page(errors: setting_errors(e.record), status: :unprocessable_content)
  end

  # POST /tenant/integrations/ai-model/test_connection
  def test_connection
    authorize :integrations, :test_ai_model?

    kind, message = check_connection
    redirect_to tenant_integration_path("ai-model"), status: :see_other, kind => message
  end

  private

  # The field-level messages ("Address must start with https://") live on the
  # config, not on the tenant, whose own message is only "is invalid".
  def setting_errors(tenant)
    config = tenant.ai_config
    config.valid?
    messages = config.errors.full_messages
    messages.presence || tenant.errors.full_messages
  end

  def settings_params
    permitted = params.expect(ai_model: [ :provider, :base_url, :model, :effort, :suggestions_enabled ]).to_h.symbolize_keys
    permitted.merge(base_url: permitted[:base_url].to_s.strip.presence, model: permitted[:model].to_s.strip.presence)
  end

  # Sends the saved model one short request. The answer shown to the admin
  # names the failure but never echoes the endpoint's response body.
  #
  # @return [Array(Symbol, String)] flash kind and message
  def check_connection
    return [ :alert, "Save a complete model and an API key first." ] unless Ai::ModelClient.configured?(current_tenant)

    adapter = Ai::ModelClient.for(current_tenant)
    reply = adapter.ping
    return [ :alert, "The endpoint answered, but the model said nothing." ] if reply.blank?

    [ :notice, "Connected. #{adapter.model} replied: “#{reply.truncate(REPLY_LIMIT)}”" ]
  rescue Ai::Errors::AuthenticationError
    [ :alert, "The endpoint rejected the API key." ]
  rescue Ai::Errors::RateLimitError
    [ :alert, "The endpoint is rate limiting us. Try again in a minute." ]
  rescue Ai::Errors::RefusalError
    [ :alert, "The model declined the test request. The key and address work." ]
  rescue Ai::Errors::ConfigurationError => e
    [ :alert, e.message ]
  rescue Ai::Errors::ApiError => e
    [ :alert, api_error_message(e) ]
  end

  def api_error_message(error)
    return "The endpoint answered with status #{error.status}. Check the address and the model id." if error.status == 404
    return "The endpoint answered with status #{error.status}." if error.status && error.status != 200

    error.message
  end

  def current_tenant
    ActsAsTenant.current_tenant
  end
end
