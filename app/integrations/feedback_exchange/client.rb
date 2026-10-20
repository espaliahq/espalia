# frozen_string_literal: true

# HTTP client for a feedback exchange peer (protocol §5).
#
# Each instance holds one tenant's peer address and outbound secret; there is no
# global state. Every request is signed per protocol §6 and carries
# `X-Exchange-Consumer: growthos`. The client does not retry: the sync job owns
# retries and backoff, as it does for HRIS.
#
# `base_url` is the peer's exchange root, prefix included
# (e.g. "https://chip.example.com/api/feedback-exchange"); endpoint paths are
# appended to it.
#
# @example
#   client = FeedbackExchange::Client.for(tenant)
#   page = client.feedback(since: tenant.feedback_exchange_config.cursor, limit: 100)
class FeedbackExchange::Client
  CONSUMER = "growthos"
  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 15

  # Builds a client from a tenant's stored config and secrets.
  #
  # @param tenant [Tenant]
  # @raise [ArgumentError] when the peer address or outbound secret is missing
  # @return [FeedbackExchange::Client]
  def self.for(tenant)
    config = tenant.feedback_exchange_config
    new(base_url: config.normalized_base_url, outbound_secret: tenant.feedback_exchange_secrets.outbound_secret)
  end

  # @param base_url [String] the peer's exchange root
  # @param outbound_secret [String] signs our requests
  # @param connection [Faraday::Connection, nil] injectable for tests
  def initialize(base_url:, outbound_secret:, connection: nil)
    raise ArgumentError, "base_url is required" if base_url.blank?
    raise ArgumentError, "outbound_secret is required" if outbound_secret.blank?

    @base_url = base_url.chomp("/")
    @outbound_secret = outbound_secret
    @connection = connection
  end

  # GET /feedback
  #
  # @param since [String, nil] opaque cursor from the previous page
  # @param limit [Integer, nil]
  # @return [Hash] { "items", "next_cursor", "has_more" }
  def feedback(since: nil, limit: nil)
    get("feedback", since: since, limit: limit)
  end

  # GET /feedback/deletions
  #
  # @param since [String, nil]
  # @param limit [Integer, nil]
  # @return [Hash] { "items", "next_cursor", "has_more" }
  def deletions(since: nil, limit: nil)
    get("feedback/deletions", since: since, limit: limit)
  end

  # POST /feedback/ack
  #
  # @param items [Array<Hash>] each { id:, remote_id:, remote_url: }
  # @return [void]
  def ack(items)
    request(:post, "feedback/ack", body: JSON.generate(items: items))
    nil
  end

  # GET /health: signed, so a green answer proves the pair shares a secret.
  #
  # @return [Hash] the peer's body, e.g. { "ok" => true, "peer" => "chip" }
  def health
    get("health")
  end

  private

  attr_reader :base_url, :outbound_secret

  def get(path, **params)
    request(:get, path, params: params.compact)
  end

  # Signs exactly what Faraday will put on the wire: the path_with_query comes
  # from the connection's own URL builder, so the query is encoded and ordered
  # the way the peer will read it.
  def request(method, path, params: {}, body: nil)
    timestamp = Time.now.to_i.to_s
    path_with_query = connection.build_exclusive_url(path, params).request_uri

    response = connection.run_request(method, path, body, headers(method:, path_with_query:, body:, timestamp:)) do |req|
      req.params.update(params)
    end
    parse(response)
  rescue Faraday::TimeoutError, Faraday::ConnectionFailed, Faraday::SSLError => e
    raise FeedbackExchange::Errors::ApiError.new(status: nil, message: "Feedback exchange peer unreachable: #{e.class.name.demodulize}")
  end

  def headers(method:, path_with_query:, body:, timestamp:)
    headers = {
      FeedbackExchange::Signature::CONSUMER_HEADER => CONSUMER,
      FeedbackExchange::Signature::TIMESTAMP_HEADER => timestamp,
      FeedbackExchange::Signature::SIGNATURE_HEADER => FeedbackExchange::Signature.sign(
        secret: outbound_secret, method:, path_with_query:, body:, timestamp:
      )
    }
    headers["Content-Type"] = "application/json" if body
    headers
  end

  def parse(response)
    case response.status
    when 200..299 then parse_json(response.body)
    when 401 then raise FeedbackExchange::Errors::AuthenticationError, "The peer rejected our signature"
    when 429 then raise FeedbackExchange::Errors::RateLimitError.new(retry_after: response.headers["Retry-After"]&.to_i)
    else raise FeedbackExchange::Errors::ApiError.new(status: response.status, body: response.body)
    end
  end

  def parse_json(body)
    return {} if body.to_s.strip.empty?

    parsed = JSON.parse(body.to_s)
    return parsed if parsed.is_a?(Hash)

    raise FeedbackExchange::Errors::ApiError.new(status: 200, body: body, message: "The peer answered with JSON that is not an object")
  rescue JSON::ParserError
    raise FeedbackExchange::Errors::ApiError.new(status: 200, body: body, message: "The peer answered with something that is not JSON")
  end

  def connection
    @connection ||= build_connection
  end

  def build_connection
    FeedbackExchange::HostGuard.check!(base_url)
    Faraday.new(url: "#{base_url}/") do |f|
      f.options.open_timeout = OPEN_TIMEOUT
      f.options.timeout = READ_TIMEOUT
      f.adapter Faraday.default_adapter
      f.headers["Accept"] = "application/json"
    end
  end
end
