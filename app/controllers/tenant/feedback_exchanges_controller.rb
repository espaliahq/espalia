# frozen_string_literal: true

# Settings for the feedback exchange with a peer system, and the connection test.
#
# The page itself is {Tenant::IntegrationsController#show} (id "feedback-exchange").
# Writes are web-only on purpose: this is a single tenant-admin page holding the
# signing secrets, which must never travel through an MCP client. The MCP surface
# is the read-only `integrations_feedback_exchange_status`.
class Tenant::FeedbackExchangesController < ApplicationController
  include FeedbackExchangePage

  # PATCH /tenant/integrations/feedback-exchange
  def update
    authorize :integrations, :update_feedback_exchange?

    current_tenant.update_feedback_exchange!(
      settings: settings_params.to_h.symbolize_keys,
      outbound_secret: secret_params[:outbound_secret],
      inbound_secret: secret_params[:inbound_secret]
    )
    redirect_to tenant_integration_path("feedback-exchange"), notice: "Feedback exchange settings saved.",
                                                               status: :see_other
  rescue ActiveRecord::RecordInvalid => e
    # The save failed, so the secrets were not stored: do not show them as stored.
    current_tenant.restore_attributes([ :feedback_exchange_credentials ])
    render_feedback_exchange_page(
      errors: e.record.errors.full_messages.map { |message| message.sub(/\AFeedback exchange config /, "") },
      status: :unprocessable_content
    )
  end

  # POST /tenant/integrations/feedback-exchange/test_connection
  def test_connection
    authorize :integrations, :test_feedback_exchange?

    result = check_connection
    redirect_to tenant_integration_path("feedback-exchange"), status: :see_other, **{ result.first => result.last }
  end

  private

  def settings_params
    params.expect(feedback_exchange: [ :base_url, :peer_name, :enabled ])
  end

  def secret_params
    params.expect(feedback_exchange: [ :outbound_secret, :inbound_secret ])
  end

  # Calls the peer's signed /health. The answer shown to the admin names the
  # failure but never echoes the peer's response body.
  #
  # @return [Array(Symbol, String)] flash kind and message
  def check_connection
    config = current_tenant.feedback_exchange_config
    return [ :alert, "Save the peer's address and our outbound secret first." ] unless
      config.normalized_base_url && current_tenant.feedback_exchange_secrets.outbound_secret

    body = FeedbackExchange::Client.for(current_tenant).health
    return [ :alert, "The peer answered, but not with { ok: true }." ] unless body["ok"] == true

    [ :notice, "Connected to #{config.peer_name.presence || 'the peer'}. Our signature was accepted." ]
  rescue FeedbackExchange::Errors::AuthenticationError
    [ :alert, "The peer rejected our signature. Check that its inbound secret matches our outbound secret." ]
  rescue FeedbackExchange::Errors::RateLimitError
    [ :alert, "The peer is rate limiting us. Try again in a minute." ]
  rescue FeedbackExchange::Errors::ApiError => e
    [ :alert, e.status ? "The peer answered with status #{e.status}." : "Could not reach the peer. Check the address." ]
  end

  def current_tenant
    ActsAsTenant.current_tenant
  end
end
