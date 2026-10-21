# frozen_string_literal: true

# The HTTP half the bearer-key JSON adapters share: one Faraday connection to
# the tenant's address, put through {Ai::HostGuard} first, and every status
# mapped to {Ai::Errors}. Faraday never follows a redirect, so the guarded
# address is the only one called.
#
# The including class provides `api_key`, `base_url` (no trailing slash) and
# may set `@connection` for tests.
module Ai::JsonEndpoint
  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 60

  private

  # @param path [String] relative to the base URL, e.g. "chat/completions"
  # @param payload [Hash]
  # @return [Hash] the parsed body of a 2xx answer
  # @raise [Ai::Errors::AuthenticationError, Ai::Errors::RateLimitError, Ai::Errors::ApiError]
  def post_json(path, payload)
    response = connection.post(path, JSON.generate(payload))
    parse_response(response)
  rescue Faraday::TimeoutError, Faraday::ConnectionFailed, Faraday::SSLError => e
    raise Ai::Errors::ApiError.new(status: nil, message: "Could not reach the model endpoint: #{e.class.name.demodulize}")
  end

  def parse_response(response)
    case response.status
    when 200..299 then parse_json(response.body)
    when 401, 403 then raise Ai::Errors::AuthenticationError, "The model endpoint rejected the API key (#{response.status})"
    when 429 then raise Ai::Errors::RateLimitError.new(retry_after: response.headers["Retry-After"]&.to_i)
    else raise Ai::Errors::ApiError.new(status: response.status, body: response.body)
    end
  end

  def parse_json(body)
    parsed = JSON.parse(body.to_s)
    return parsed if parsed.is_a?(Hash)

    raise Ai::Errors::ApiError.new(status: 200, body: body, message: "The model endpoint answered with JSON that is not an object")
  rescue JSON::ParserError
    raise Ai::Errors::ApiError.new(status: 200, body: body, message: "The model endpoint answered with something that is not JSON")
  end

  def connection
    @connection ||= begin
      Ai::HostGuard.check!(base_url)
      Faraday.new(url: "#{base_url}/") do |f|
        f.options.open_timeout = OPEN_TIMEOUT
        f.options.timeout = READ_TIMEOUT
        f.adapter Faraday.default_adapter
        f.headers["Authorization"] = "Bearer #{api_key}"
        f.headers["Content-Type"] = "application/json"
        f.headers["Accept"] = "application/json"
      end
    end
  end
end
