# frozen_string_literal: true

# The API key for a tenant's AI model, read from Tenant#ai_credentials.
#
# `inspect` and `to_s` never print the value, so an exception or a log line
# that captures the object cannot leak it.
class AiModelCredentials
  # @param raw [Hash, nil] the decoded credentials column
  def initialize(raw)
    @raw = raw.is_a?(Hash) ? raw.slice("api_key") : {}
  end

  # @return [String, nil]
  def api_key = @raw["api_key"].presence

  # @return [Boolean]
  def api_key? = api_key.present?

  def inspect = "#<#{self.class.name} api_key=#{api_key?}>"
  alias_method :to_s, :inspect
end
