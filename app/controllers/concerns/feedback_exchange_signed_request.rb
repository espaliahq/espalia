# frozen_string_literal: true

# Authenticates an inbound feedback exchange request by its signature (protocol
# §6) and resolves the tenant from it. The signature is the only credential:
# there is no session, no Devise and no CSRF.
#
# Include in a controller that inherits ActionController::Base and call
# `around_action :authenticate_feedback_exchange_request!`. The tenant is the one
# whose inbound secret (or its previous one, inside the rotation window) verifies
# the request; the action then runs inside `ActsAsTenant.with_tenant`.
#
# Answers: 401 for a missing, stale, invalid or replayed signature; 404 once the
# signature verifies against a tenant whose exchange is switched off.
module FeedbackExchangeSignedRequest
  extend ActiveSupport::Concern

  included do
    skip_forgery_protection
  end

  # A signature is unique to one body, path and timestamp, so claiming it once
  # is the replay guard. A timestamp is fresh from MAX_SKEW before now to
  # MAX_SKEW after it, so a signature stays acceptable for up to twice MAX_SKEW
  # and the claim has to outlast that.
  REPLAY_WINDOW = FeedbackExchange::Signature::MAX_SKEW * 2

  private

  def authenticate_feedback_exchange_request!(&action)
    return head :unauthorized unless signature_headers_present? && fresh_timestamp?

    tenant = signing_tenant
    return head :unauthorized if tenant.nil?
    return head :not_found unless tenant.feedback_exchange_config.enabled?
    return head :unauthorized unless claim_feedback_exchange_signature!

    ActsAsTenant.with_tenant(tenant, &action)
  end

  def signature_headers_present?
    request.headers[FeedbackExchange::Signature::SIGNATURE_HEADER].present? &&
      request.headers[FeedbackExchange::Signature::TIMESTAMP_HEADER].present?
  end

  # A stale or malformed timestamp is refused before any tenant is loaded and
  # decrypted, so an unauthenticated flood costs no more than a header check.
  def fresh_timestamp?
    timestamp = Integer(request.headers[FeedbackExchange::Signature::TIMESTAMP_HEADER].to_s, 10)
    (Time.current.to_i - timestamp).abs <= FeedbackExchange::Signature::MAX_SKEW
  rescue ArgumentError
    false
  end

  # @return [Tenant, nil] the tenant whose inbound secret signed this request
  def signing_tenant
    body = request.raw_post
    Tenant.where.not(feedback_exchange_credentials: nil).find_each do |tenant|
      secrets = tenant.feedback_exchange_secrets
      next if secrets.inbound_secret.blank?

      verified = FeedbackExchange::Signature.verify(
        signature: request.headers[FeedbackExchange::Signature::SIGNATURE_HEADER],
        timestamp: request.headers[FeedbackExchange::Signature::TIMESTAMP_HEADER],
        secret: secrets.inbound_secret,
        previous_secret: secrets.previous_inbound_secret,
        previous_rotated_at: secrets.previous_rotated_at,
        method: request.request_method,
        path_with_query: request.fullpath,
        body: body
      )
      return tenant if verified
    end
    nil
  end

  # @return [Boolean] false when this signed request was already accepted
  def claim_feedback_exchange_signature!
    key = "feedback_exchange:request:#{request.headers[FeedbackExchange::Signature::SIGNATURE_HEADER]}"
    Rails.cache.write(key, true, unless_exist: true, expires_in: REPLAY_WINDOW)
  end
end
