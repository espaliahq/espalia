# frozen_string_literal: true

# Validates HiBob webhook signatures using HMAC-SHA512.
#
# @example
#   valid = Hris::Hibob::WebhookValidator.valid?(
#     payload: request.raw_post,
#     signature: request.headers["X-Bob-Signature"],
#     secret: tenant.hris_config.webhook_secret
#   )
#
class Hris::Hibob::WebhookValidator
  # Verifies an HMAC-SHA512 signature.
  #
  # @param payload [String] raw request body
  # @param signature [String] signature from the request header
  # @param secret [String] shared webhook secret
  # @return [Boolean]
  def self.valid?(payload:, signature:, secret:)
    return false if payload.blank? || signature.blank? || secret.blank?

    expected = OpenSSL::HMAC.hexdigest("SHA512", secret, payload)
    ActiveSupport::SecurityUtils.secure_compare(expected, signature)
  end
end
