# frozen_string_literal: true

# The level field picker on the HRIS connection form, loaded as a lazy frame so
# the page never waits on the HRIS. Read-only: the choice saves with the rest of
# the connection through {Tenant::HrisConnectionsController#update}.
#
# Not an MCP tool: it exists to fill one web form, and the connection it feeds
# is written only on the web.
class Tenant::HrisLevelFieldsController < ApplicationController
  # GET /tenant/integrations/hris/level_field?current=<the form's value>
  def show
    authorize :integrations, :update_hris_connection?

    tenant = ActsAsTenant.current_tenant
    render Views::Integrations::HrisLevelFieldFrame.new(**picker(tenant))
  end

  private

  # The page passes the value its form holds, which after a rejected save is
  # what the admin chose rather than what is stored.
  def requested_value(tenant)
    params.key?(:current) ? params[:current].to_s.strip.presence : tenant.hris_config.level_field_id
  end

  # @return [Hash] `current:` and either `fields:` or `problem:` for the frame
  def picker(tenant)
    current = requested_value(tenant)
    unless tenant.hris_config.connected?(tenant)
      return { current:, problem: Views::Integrations::HrisLevelFieldFrame::NOT_CONNECTED }
    end

    adapter = Hris::BaseAdapter.for(tenant)
    { current: adapter.catalogue_id(current), fields: adapter.field_catalogue }
  rescue Hris::Hibob::Errors::AuthenticationError
    { current:, problem: "The HRIS refused the stored credentials." }
  rescue Hris::Hibob::Errors::RateLimitError
    { current:, problem: "The HRIS is limiting requests just now. Reload the page in a minute." }
  rescue StandardError => e
    # The frame only reads, and a frame with no field would drop the level
    # field from the form, so any failure keeps the value and says so.
    Rails.error.report(e, handled: true, context: { tenant_id: tenant.id })
    { current:, problem: "The HRIS did not answer as expected. Reload the page to try again." }
  end
end
