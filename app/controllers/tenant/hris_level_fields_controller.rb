# frozen_string_literal: true

# The level field picker on the HRIS connection form, loaded as a lazy frame so
# the page never waits on the HRIS. Read-only: the choice saves with the rest of
# the connection through {Tenant::HrisConnectionsController#update}.
#
# Not an MCP tool: it exists to fill one web form, and the connection it feeds
# is written only on the web.
class Tenant::HrisLevelFieldsController < ApplicationController
  # GET /tenant/integrations/hris/level_field
  def show
    authorize :integrations, :update_hris_connection?

    tenant = ActsAsTenant.current_tenant
    render Views::Integrations::HrisLevelFieldFrame.new(current: tenant.hris_config.level_field_id, **catalogue(tenant))
  end

  private

  # @return [Hash] `fields:` the catalogue, or `problem:` why it could not be read
  def catalogue(tenant)
    return { problem: Views::Integrations::HrisLevelFieldFrame::NOT_CONNECTED } unless connected?(tenant)

    { fields: Hris::BaseAdapter.for(tenant).field_catalogue }
  rescue Hris::Hibob::Errors::AuthenticationError
    { problem: "The HRIS refused the stored credentials." }
  rescue Hris::Hibob::Errors::RateLimitError
    { problem: "The HRIS is limiting requests just now. Reload the page in a minute." }
  rescue Hris::Hibob::Errors::Error, Faraday::Error => e
    Rails.logger.warn("[HrisLevelFields] catalogue unavailable for tenant #{tenant.id}: #{e.class}")
    { problem: "The HRIS did not answer as expected. Reload the page to try again." }
  end

  def connected?(tenant)
    HrisConfig::PROVIDERS.include?(tenant.hris_config.provider) && tenant.hris_secrets.complete?
  end
end
