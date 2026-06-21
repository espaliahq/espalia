# frozen_string_literal: true

# Slack integration namespace + app-level (not per-tenant) OAuth configuration.
#
# The bot token is stored per tenant (see Tenant#connect_slack!); the values
# here are the GrowthOS Slack *app* credentials, shared across tenants, read
# from Rails credentials with an ENV fallback for dev/CI.
module Slack
  AUTHORIZE_URL = "https://slack.com/oauth/v2/authorize"

  # Bot scopes requested at install. The grant comes from THIS list (the OAuth
  # authorize URL's `scope` param) — not the manifest — so it must carry every
  # scope we want the token to hold. The first three power today's outbound DM
  # notifications; `commands` and `im:history` are pre-granted so the planned
  # inbound features (a /growthos slash command, free-text DM-reply capture) can
  # ship as config-only changes with NO reinstall. Keep in sync with
  # app/integrations/slack/manifest.yml.
  BOT_SCOPES = %w[chat:write users:read.email im:write commands im:history].freeze

  # @return [Hash] { client_id:, client_secret:, signing_secret: }
  def self.oauth_config
    creds = Rails.application.credentials.slack
    {
      client_id: creds&.dig(:client_id) || ENV["SLACK_CLIENT_ID"],
      client_secret: creds&.dig(:client_secret) || ENV["SLACK_CLIENT_SECRET"],
      signing_secret: creds&.dig(:signing_secret) || ENV["SLACK_SIGNING_SECRET"]
    }
  end

  # @return [Boolean] whether the app is configured to run the OAuth install flow
  def self.configured?
    config = oauth_config
    config[:client_id].present? && config[:client_secret].present?
  end
end
