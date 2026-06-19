# frozen_string_literal: true

# Per-tenant Slack install via OAuth v2.
#
#   install  → redirect to Slack's consent screen (state stored in session)
#   callback → verify state, exchange the code for a bot token, persist it
#   destroy  → disconnect the workspace
#
# Tenant-admin only. The app-level client credentials come from {Slack.oauth_config};
# the resulting bot token is stored per tenant by Tenant#connect_slack!.
class Tenant::SlackConnectionsController < ApplicationController
  SESSION_STATE_KEY = :slack_oauth_state

  # GET /tenant/slack/install
  def install
    authorize :integrations, :connect?

    unless Slack.configured?
      return redirect_to tenant_integrations_path, alert: "Slack is not configured for this deployment."
    end

    state = SecureRandom.hex(24)
    session[SESSION_STATE_KEY] = state
    redirect_to slack_authorize_url(state), allow_other_host: true
  end

  # GET /tenant/slack/callback
  def callback
    authorize :integrations, :connect?

    expected = session.delete(SESSION_STATE_KEY)
    return redirect_with_alert("Slack connection could not be verified. Please try again.") if invalid_state?(expected)
    return redirect_with_alert("Slack connection was cancelled.") if params[:error].present? || params[:code].blank?

    result = Slack::Client.exchange_oauth_code(
      code: params[:code],
      client_id: Slack.oauth_config[:client_id],
      client_secret: Slack.oauth_config[:client_secret],
      redirect_uri: tenant_slack_callback_url
    )
    current_tenant.connect_slack!(
      bot_token: result["bot_token"],
      team_id: result["team_id"],
      team_name: result["team_name"],
      installed_by: current_person&.id
    )
    redirect_to tenant_integrations_path, notice: "Slack connected to #{result["team_name"] || "your workspace"}."
  rescue Slack::Errors::Error => e
    Rails.logger.warn("[slack] install failed: #{e.class}: #{e.message}")
    redirect_with_alert("Slack connection failed. Please try again.")
  end

  # DELETE /tenant/slack
  def destroy
    authorize :integrations, :disconnect?
    current_tenant.disconnect_slack!
    redirect_to tenant_integrations_path, notice: "Slack disconnected."
  end

  private

  def invalid_state?(expected)
    expected.blank? || params[:state].blank? ||
      !ActiveSupport::SecurityUtils.secure_compare(params[:state], expected)
  end

  def slack_authorize_url(state)
    query = {
      client_id: Slack.oauth_config[:client_id],
      scope: Slack::BOT_SCOPES.join(","),
      redirect_uri: tenant_slack_callback_url,
      state: state
    }
    "#{Slack::AUTHORIZE_URL}?#{query.to_query}"
  end

  def redirect_with_alert(message)
    redirect_to tenant_integrations_path, alert: message
  end

  def current_tenant
    ActsAsTenant.current_tenant
  end
end
