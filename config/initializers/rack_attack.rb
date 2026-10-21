# frozen_string_literal: true

# Throttle for the MCP OAuth Dynamic Client Registration endpoint.
# The endpoint is intentionally public (that's how DCR works — clients
# self-register without auth), but it persists database rows, so an
# untrusted client can spam-register and bloat the table indefinitely.
# 30/hour/IP is generous for legitimate use (each fresh CLI install on a
# given machine creates one row, lasting for the lifetime of the install)
# and tight enough that a scripted abuser hits the wall fast.
#
# Disabled in test (the discovery test posts repeatedly from 127.0.0.1)
# and in development to avoid surprising contributors. The feedback
# exchange's signed endpoints are throttled below; other endpoints are not
# throttled here — add them as load patterns warrant.
unless Rails.env.test? || Rails.env.development?
  Rack::Attack.throttle("oauth/register", limit: 30, period: 1.hour) do |req|
    req.ip if req.post? && req.path == "/oauth/register"
  end

  # The feedback exchange is signed, but verifying a request still decrypts each
  # credentialed tenant, so an unsigned flood is capped per IP.
  Rack::Attack.throttle("feedback_exchange", limit: 120, period: 1.minute) do |req|
    req.ip if req.path.start_with?("/api/feedback_exchange/")
  end

  Rack::Attack.throttled_responder = lambda do |req|
    period = req.env.dig("rack.attack.match_data", :period) || 3600
    [
      429,
      { "Content-Type" => "application/json", "Retry-After" => period.to_i.to_s },
      [ { error: "rate_limited", error_description: "too many requests" }.to_json ]
    ]
  end
end
