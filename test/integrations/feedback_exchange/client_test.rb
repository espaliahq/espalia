# frozen_string_literal: true

require "test_helper"

class FeedbackExchange::ClientTest < ActiveSupport::TestCase
  BASE = "https://chip.example.com/api/feedback-exchange"
  SECRET = "outbound-secret-outbound-secret-xx"

  setup do
    @stubs = Faraday::Adapter::Test::Stubs.new
    connection = Faraday.new(url: "#{BASE}/") do |f|
      f.adapter :test, @stubs
      f.headers["Accept"] = "application/json"
    end
    @client = FeedbackExchange::Client.new(base_url: BASE, outbound_secret: SECRET, connection: connection)
  end

  def json(body) = [ 200, { "Content-Type" => "application/json" }, body.to_json ]

  def assert_signed(env, body: "")
    assert_equal "growthos", env.request_headers["X-Exchange-Consumer"]
    assert_equal FeedbackExchange::Signature.key_id(SECRET), env.request_headers["X-Exchange-Key-Id"]
    assert FeedbackExchange::Signature.verify(
      signature: env.request_headers["X-Exchange-Signature"],
      timestamp: env.request_headers["X-Exchange-Timestamp"],
      secret: SECRET,
      method: env.method.to_s,
      path_with_query: env.url.request_uri,
      body: body
    ), "request was not signed over what was sent"
  end

  context "#feedback" do
    should "send a signed GET with the cursor and limit" do
      seen = nil
      @stubs.get("/api/feedback-exchange/feedback") do |env|
        seen = env
        json(items: [ { id: "1" } ], next_cursor: "c2", has_more: true)
      end

      page = @client.feedback(since: "c1/+=", limit: 50)

      assert_equal "c2", page["next_cursor"]
      assert page["has_more"]
      assert_signed seen
      assert_equal "/api/feedback-exchange/feedback", seen.url.path
      assert_equal({ "since" => "c1/+=", "limit" => "50" }, Rack::Utils.parse_query(seen.url.query))
    end

    should "omit params it was not given" do
      seen = nil
      @stubs.get("/api/feedback-exchange/feedback") { |env| seen = env; json(items: []) }

      @client.feedback

      assert_nil seen.url.query
      assert_signed seen
    end
  end

  context "#deletions" do
    should "call the deletions feed" do
      seen = nil
      @stubs.get("/api/feedback-exchange/feedback/deletions") { |env| seen = env; json(items: []) }

      assert_equal [], @client.deletions(since: "x", limit: 5)["items"]
      assert_signed seen
    end
  end

  context "#ack" do
    should "POST the items with the body signed" do
      seen = nil
      @stubs.post("/api/feedback-exchange/feedback/ack") { |env| seen = env; [ 204, {}, "" ] }
      items = [ { id: "1", remote_id: "e-1", remote_url: "https://g/x" } ]

      assert_nil @client.ack(items)

      assert_equal JSON.generate(items: items), seen.request_body
      assert_signed seen, body: seen.request_body
    end
  end

  context "#health" do
    should "return the peer's body" do
      @stubs.get("/api/feedback-exchange/health") { json(ok: true, peer: "chip") }

      assert_equal({ "ok" => true, "peer" => "chip" }, @client.health)
    end
  end

  context "errors" do
    should "raise AuthenticationError on 401" do
      @stubs.get("/api/feedback-exchange/health") { [ 401, {}, "" ] }
      assert_raises(FeedbackExchange::Errors::AuthenticationError) { @client.health }
    end

    should "raise RateLimitError on 429 with Retry-After" do
      @stubs.get("/api/feedback-exchange/feedback") { [ 429, { "Retry-After" => "42" }, "" ] }
      error = assert_raises(FeedbackExchange::Errors::RateLimitError) { @client.feedback }
      assert_equal 42, error.retry_after
    end

    should "raise RateLimitError without Retry-After" do
      @stubs.get("/api/feedback-exchange/feedback") { [ 429, {}, "" ] }
      assert_nil assert_raises(FeedbackExchange::Errors::RateLimitError) { @client.feedback }.retry_after
    end

    should "raise ApiError on 5xx" do
      @stubs.get("/api/feedback-exchange/feedback") { [ 503, {}, "down" ] }
      error = assert_raises(FeedbackExchange::Errors::ApiError) { @client.feedback }
      assert_equal 503, error.status
      assert_equal "down", error.body
    end

    should "raise ApiError on an unexpected 4xx" do
      @stubs.get("/api/feedback-exchange/feedback") { [ 400, {}, "bad cursor" ] }
      assert_equal 400, assert_raises(FeedbackExchange::Errors::ApiError) { @client.feedback }.status
    end

    should "raise PeerDisabled on 404, still an ApiError for callers that only know that" do
      @stubs.get("/api/feedback-exchange/feedback") { [ 404, {}, "" ] }
      error = assert_raises(FeedbackExchange::Errors::PeerDisabled) { @client.feedback }
      assert_kind_of FeedbackExchange::Errors::ApiError, error
      assert_equal 404, error.status
    end

    should "raise Conflict on a 409 to an ack" do
      @stubs.post("/api/feedback-exchange/feedback/ack") { [ 409, {}, '{"error":"remote-id-conflict"}' ] }
      error = assert_raises(FeedbackExchange::Errors::Conflict) { @client.ack([ { id: "a", remote_id: "b", remote_url: "https://x.example" } ]) }
      assert_equal 409, error.status
    end

    should "raise ApiError when the peer is unreachable" do
      @stubs.get("/api/feedback-exchange/health") { raise Faraday::ConnectionFailed, "no route" }
      error = assert_raises(FeedbackExchange::Errors::ApiError) { @client.health }
      assert_nil error.status
    end

    should "raise ApiError on a body that is not JSON" do
      @stubs.get("/api/feedback-exchange/health") { [ 200, {}, "<html>" ] }
      assert_raises(FeedbackExchange::Errors::ApiError) { @client.health }
    end

    should "raise ApiError on JSON that is not an object" do
      @stubs.get("/api/feedback-exchange/health") { [ 200, {}, "[1]" ] }
      assert_raises(FeedbackExchange::Errors::ApiError) { @client.health }
    end

    should "not retry" do
      calls = 0
      @stubs.get("/api/feedback-exchange/feedback") { calls += 1; [ 503, {}, "" ] }
      assert_raises(FeedbackExchange::Errors::ApiError) { @client.feedback }
      assert_equal 1, calls
    end
  end

  context "with the real connection" do
    should "refuse a peer address that resolves to a private address" do
      client = FeedbackExchange::Client.new(base_url: "https://sneaky.example.com/x", outbound_secret: SECRET)

      Addrinfo.stub(:getaddrinfo, [ Addrinfo.ip("10.0.0.5") ]) do
        error = assert_raises(FeedbackExchange::Errors::AddressRefused) { client.health }
        assert_match(/private network/, error.message)
      end
    end

    should "refuse a loopback written in a form only the system resolver understands" do
      client = FeedbackExchange::Client.new(base_url: "https://127.1/x", outbound_secret: SECRET)

      assert_raises(FeedbackExchange::Errors::AddressRefused) { client.health }
    end
  end

  context "connecting to the accepted address" do
    should "connect to the address the guard returned while the Host header keeps the peer's name" do
      server = TCPServer.new("127.0.0.1", 0)
      port = server.addr[1]
      seen = {}
      thread = Thread.new do
        socket = server.accept
        request = []
        while (line = socket.gets) && line != "\r\n"
          request << line
        end
        seen[:host] = request.find { |l| l.start_with?("Host:") }&.strip
        body = { ok: true, peer: "chip" }.to_json
        socket.write "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}"
        socket.close
      end

      client = FeedbackExchange::Client.new(base_url: "http://rebind.invalid:#{port}/api", outbound_secret: SECRET)

      # "rebind.invalid" never resolves: only the pinned address can answer.
      FeedbackExchange::HostGuard.stub(:check!, "127.0.0.1") do
        assert_equal({ "ok" => true, "peer" => "chip" }, client.health)
      end
      thread.join(5)

      assert_equal "Host: rebind.invalid:#{port}", seen[:host]
    ensure
      server&.close
      thread&.kill
    end
  end

  context ".for" do
    should "build from the tenant's config and secrets" do
      tenant = create(:tenant)
      tenant.update!(feedback_exchange_config: FeedbackExchangeConfig.new(base_url: "https://chip.example.com/x/", peer_name: "chip"))
      tenant.update_feedback_exchange!(outbound_secret: SECRET, inbound_secret: "inbound-for-the-client-test-0123456789abcdef0123456789")

      assert_instance_of FeedbackExchange::Client, FeedbackExchange::Client.for(tenant)
    end

    should "refuse a tenant with no outbound secret" do
      tenant = create(:tenant)
      tenant.update!(feedback_exchange_config: FeedbackExchangeConfig.new(base_url: "https://chip.example.com/x"))

      assert_raises(ArgumentError) { FeedbackExchange::Client.for(tenant) }
    end
  end
end
