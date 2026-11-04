# frozen_string_literal: true

# Settings for the HRIS connection: provider, sync options and credentials.
#
# The page itself is {Tenant::IntegrationsController#show} (id "hris").
# Writes are web-only on purpose: this is a single tenant-admin page holding an
# API token and a webhook secret, which must never travel through an MCP
# client. The MCP surface is the read-only `integrations_hris_titles`.
class Tenant::HrisConnectionsController < ApplicationController
  include HrisPage

  # PATCH /tenant/integrations/hris/connection
  def update
    authorize :integrations, :update_hris_connection?

    current_tenant.update_hris!(settings: settings_params, **credential_params)
    redirect_to tenant_integration_path("hris"), notice: "HRIS connection saved.", status: :see_other
  rescue ActiveRecord::RecordInvalid => e
    render_hris_page(errors: setting_errors(e.record), status: :unprocessable_content)
  end

  private

  # The field-level messages ("Provider is not included in the list") live on
  # the config, not on the tenant, whose own message is only "is invalid".
  def setting_errors(tenant)
    config = tenant.hris_config
    config.valid?
    messages = config.errors.full_messages
    messages.presence || tenant.errors.full_messages
  end

  def settings_params
    permitted = params.expect(hris_connection: [ :provider, :level_field_id, :sync_enabled ]).to_h.symbolize_keys
    {
      provider: permitted[:provider].to_s.strip.presence,
      sync_enabled: permitted[:sync_enabled],
      level_field_id: permitted[:level_field_id].to_s.strip.presence
    }
  end

  # @return [Hash] write-only credential fields; a blank keeps the stored value
  def credential_params
    permitted = params.expect(hris_connection: [ :service_user_id, :api_token, :webhook_secret ]).to_h.symbolize_keys
    permitted.transform_values { |value| value.is_a?(String) ? value : nil }
  end

  def current_tenant
    ActsAsTenant.current_tenant
  end
end
