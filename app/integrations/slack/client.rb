# frozen_string_literal: true

# Minimal Slack Web API client scoped to a single workspace's bot token.
#
# The surface the notifications and the feedback modal need: resolve a user
# by email or id, open a DM channel, post a message, open a modal, fetch a
# message permalink. The OAuth code exchange is a class method (it
# authenticates with the app's client credentials, not a bot token).
#
# Slack always responds HTTP 200 with an `ok` boolean; on `ok: false` we raise
# {Slack::Errors::ApiError} (or AuthenticationError for token problems).
#
# @example
#   client = Slack::Client.new(bot_token: tenant.slack_bot_token)
#   uid = client.lookup_user_id_by_email("alex@acme.com")
#   client.post_dm(slack_user_id: uid, text: "Hi", blocks: [...]) if uid
class Slack::Client
  BASE_URL = "https://slack.com/api/"
  AUTH_ERRORS = %w[invalid_auth account_inactive token_revoked not_authed no_permission].freeze
  OPEN_TIMEOUT = 2
  READ_TIMEOUT = 5

  # @param bot_token [String] workspace bot token (xoxb-…)
  def initialize(bot_token:)
    @bot_token = bot_token
  end

  # Resolve a Slack user id from an email. Returns nil when the email isn't a
  # member of the workspace (a normal, non-exceptional outcome).
  #
  # @param email [String]
  # @return [String, nil]
  def lookup_user_id_by_email(email)
    body = get("users.lookupByEmail", email: email)
    body.dig("user", "id")
  rescue Slack::Errors::ApiError => e
    return nil if e.code == "users_not_found"

    raise
  end

  # Open (or fetch) the DM channel with a user.
  #
  # @param slack_user_id [String]
  # @return [String] the DM channel id
  def open_dm(slack_user_id)
    post("conversations.open", users: slack_user_id).dig("channel", "id")
  end

  # Post a direct message to a user, opening the DM channel first.
  #
  # @param slack_user_id [String]
  # @param text [String] fallback text (notifications, accessibility)
  # @param blocks [Array<Hash>, nil] Block Kit payload
  # @return [Hash] the Slack response
  def post_dm(slack_user_id:, text:, blocks: nil)
    channel = open_dm(slack_user_id)
    payload = { channel: channel, text: text }
    payload[:blocks] = blocks if blocks
    post("chat.postMessage", **payload)
  end

  # The email Slack holds for a user — the key GrowthOS matches a member on.
  # Nil when Slack withholds it (a guest, a deactivated account).
  #
  # @param slack_user_id [String]
  # @return [String, nil]
  def user_email(slack_user_id)
    get("users.info", user: slack_user_id).dig("user", "profile", "email").presence
  rescue Slack::Errors::ApiError => e
    return nil if e.code == "user_not_found"

    raise
  end

  # Open a modal in response to an interaction. Slack honours the trigger_id
  # for three seconds, so call this before any slower work.
  #
  # @param trigger_id [String]
  # @param view [Hash] a Block Kit modal view
  # @return [Hash] the Slack response
  def open_view(trigger_id:, view:)
    post("views.open", trigger_id: trigger_id, view: view)
  end

  # A permanent link to one message, for the external reference of feedback
  # given from a message shortcut.
  #
  # @param channel [String]
  # @param message_ts [String]
  # @return [String, nil]
  def permalink(channel:, message_ts:)
    get("chat.getPermalink", channel: channel, message_ts: message_ts)["permalink"]
  rescue Slack::Errors::ApiError
    nil
  end

  # Exchange an OAuth authorization code for a bot token (install flow).
  #
  # @return [Hash] { "bot_token" =>, "team_id" =>, "team_name" => }
  # @raise [Slack::Errors::ApiError]
  def self.exchange_oauth_code(code:, client_id:, client_secret:, redirect_uri:)
    conn = Faraday.new(url: BASE_URL) do |f|
      f.request :url_encoded
      f.response :json
      f.options.open_timeout = OPEN_TIMEOUT
      f.options.timeout = READ_TIMEOUT
      f.adapter Faraday.default_adapter
    end
    body = conn.post("oauth.v2.access", {
      code: code, client_id: client_id, client_secret: client_secret, redirect_uri: redirect_uri
    }).body
    raise Slack::Errors::ApiError.new(code: body["error"]) unless body["ok"]

    { "bot_token" => body["access_token"], "team_id" => body.dig("team", "id"), "team_name" => body.dig("team", "name") }
  rescue Faraday::Error
    raise Slack::Errors::ApiError.new(code: "transport_error")
  end

  private

  attr_reader :bot_token

  def connection
    @connection ||= Faraday.new(url: BASE_URL) do |f|
      f.request :json
      f.response :json
      f.options.open_timeout = OPEN_TIMEOUT
      f.options.timeout = READ_TIMEOUT
      f.adapter Faraday.default_adapter
      f.headers["Authorization"] = "Bearer #{bot_token}"
    end
  end

  # Wrap transport failures (timeouts, connection refused) in the Slack::Errors
  # contract so callers — esp. the best-effort DM delivery method — don't see a
  # raw Faraday error and retry the job forever.
  def get(method, **params)
    check!(connection.get(method, params).body)
  rescue Faraday::Error
    raise Slack::Errors::ApiError.new(code: "transport_error")
  end

  def post(method, **payload)
    check!(connection.post(method, payload).body)
  rescue Faraday::Error
    raise Slack::Errors::ApiError.new(code: "transport_error")
  end

  # @raise [Slack::Errors::AuthenticationError, Slack::Errors::ApiError]
  def check!(body)
    return body if body["ok"]

    code = body["error"]
    raise Slack::Errors::AuthenticationError, code if AUTH_ERRORS.include?(code)

    raise Slack::Errors::ApiError.new(code: code)
  end
end
