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
# and in development to avoid surprising contributors. Other endpoints
# are not throttled here — add them as load patterns warrant.
unless Rails.env.test? || Rails.env.development?
  Rack::Attack.throttle("oauth/register", limit: 30, period: 1.hour) do |req|
    req.ip if req.post? && req.path == "/oauth/register"
  end

  Rack::Attack.throttled_responder = lambda do |req|
    [
      429,
      { "Content-Type" => "application/json", "Retry-After" => "3600" },
      [ { error: "rate_limited", error_description: "too many registration requests" }.to_json ]
    ]
  end
end
