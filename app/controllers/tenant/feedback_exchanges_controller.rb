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
      settings: settings,
      outbound_secret: form_params[:outbound_secret],
      inbound_secret: form_params[:inbound_secret]
    )
    redirect_to tenant_integration_path("feedback-exchange"), notice: "Feedback exchange settings saved.",
                                                               status: :see_other
  rescue ActiveRecord::RecordInvalid => e
    render_feedback_exchange_page(errors: setting_errors(e.record), status: :unprocessable_content)
  end

  # POST /tenant/integrations/feedback-exchange/test_connection
  def test_connection
    authorize :integrations, :test_feedback_exchange?

    result = check_connection
    redirect_to tenant_integration_path("feedback-exchange"), status: :see_other, **{ result.first => result.last }
  end

  private

  # The field-level messages ("Base url must be a plain address...") live on the
  # config, not on the tenant, whose own message is only "is invalid".
  def setting_errors(tenant)
    config = tenant.feedback_exchange_config
    config.valid?
    others = tenant.errors.full_messages.grep_v(/\AFeedback exchange config/)
    (config.errors.full_messages + others).presence || tenant.errors.full_messages
  end

  def form_params
    @form_params ||= params.expect(
      feedback_exchange: [ :base_url, :peer_name, :enabled, :outbound_secret, :inbound_secret,
                           import_kinds: [], export_kinds: [] ]
    )
  end

  # The checkbox groups submit a leading blank so that unticking every box is
  # still a value; drop it. A ticked "All types" wins over any box ticked beside
  # it, which is what a browser without JavaScript posts.
  def settings
    form_params.slice(:base_url, :peer_name, :enabled, :import_kinds, :export_kinds).to_h.symbolize_keys.tap do |attrs|
      %i[import_kinds export_kinds].each { |key| attrs[key] = chosen_kinds(attrs[key]) if attrs.key?(key) }
    end
  end

  def chosen_kinds(kinds)
    kinds = kinds.compact_blank.uniq
    kinds.include?(FeedbackExchangeConfig::ALL_KINDS) ? [ FeedbackExchangeConfig::ALL_KINDS ] : kinds
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

    allowance = if FeedbackExchange::HostGuard.development_allowance?(config.normalized_base_url)
      " Its address is on a private network, which only development allows."
    end
    [ :notice, "Connected to #{config.peer_name.presence || 'the peer'}. Our signature was accepted.#{allowance}" ]
  rescue FeedbackExchange::Errors::AddressRefused => e
    [ :alert, "#{e.message}." ]
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
