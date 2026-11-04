# frozen_string_literal: true

# The HRIS API credentials for a tenant, read from Tenant#hris_credentials.
#
# `service_user_id` and `api_token` authenticate the sync; `webhook_secret`
# verifies inbound HRIS webhooks (HMAC, see {Hris::Hibob::WebhookValidator}).
#
# `inspect` and `to_s` never print a value, so an exception or a log line that
# captures the object cannot leak one.
class HrisCredentials
  KEYS = %w[service_user_id api_token webhook_secret].freeze

  # @param raw [Hash, nil] the decoded credentials column
  def initialize(raw)
    @raw = raw.is_a?(Hash) ? raw.slice(*KEYS) : {}
  end

  # @return [String, nil] the HRIS service account's user id
  def service_user_id = @raw["service_user_id"].presence

  # @return [String, nil] the HRIS API token
  def api_token = @raw["api_token"].presence

  # @return [String, nil] verifies inbound HRIS webhooks
  def webhook_secret = @raw["webhook_secret"].presence

  # @return [Boolean] whether the sync can authenticate
  def complete? = service_user_id.present? && api_token.present?

  # @return [Hash{String => Boolean}] which values are set, for display
  def stored
    KEYS.index_with { |key| @raw[key].present? }
  end

  def inspect = "#<#{self.class.name} service_user_id=#{service_user_id.present?} api_token=#{api_token.present?} webhook_secret=#{webhook_secret.present?}>"
  alias_method :to_s, :inspect
end
