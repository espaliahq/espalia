# frozen_string_literal: true

require "test_helper"

# The wire: what goes out to /chat/completions and what comes back. Faraday's
# test adapter stands in for the endpoint; nothing here reaches the network.
class Ai::OpenAiCompatible::AdapterTest < ActiveSupport::TestCase
  BASE = "https://ai-gateway.vercel.sh/v1"
  MODEL = "anthropic/claude-opus-5-5"
  SCHEMA = { type: "object", additionalProperties: false, required: [ "suggestions" ] }.freeze

  setup do
    @stubs = Faraday::Adapter::Test::Stubs.new
    connection = Faraday.new(url: "#{BASE}/") do |f|
      f.adapter :test, @stubs
      f.headers["Authorization"] = "Bearer sk-gw"
      f.headers["Content-Type"] = "application/json"
    end
    @adapter = Ai::OpenAiCompatible::Adapter.new(api_key: "sk-gw", base_url: "#{BASE}/", model: MODEL, connection: connection)
  end

  def json(body, status: 200, headers: {}) = [ status, { "Content-Type" => "application/json" }.merge(headers), body.to_json ]

  def completion(content, finish_reason: "stop", refusal: nil)
    { model: "anthropic/claude-opus-5-5", usage: { prompt_tokens: 200, completion_tokens: 40 },
      choices: [ { finish_reason: finish_reason, message: { role: "assistant", content: content, refusal: refusal } } ] }
  end

  def limit_params(base_url:, model:)
    stubs = Faraday::Adapter::Test::Stubs.new
    body = nil
    stubs.post("/v1/chat/completions") { |env| body = JSON.parse(env.body); json(completion("ready")) }
    connection = Faraday.new(url: "#{base_url}/") { |f| f.adapter :test, stubs }
    Ai::OpenAiCompatible::Adapter.new(api_key: "k", base_url: base_url, model: model, connection: connection).ping
    body.slice("max_tokens", "max_completion_tokens").keys
  end

  def suggest = @adapter.suggest(system: "framework", user: "item", schema: SCHEMA)

  should "post the schema as strict response_format, with the system text first and the item last" do
    body = nil
    authorization = nil
    @stubs.post("/v1/chat/completions") do |env|
      body = JSON.parse(env.body)
      authorization = env.request_headers["Authorization"]
      json(completion({ suggestions: [] }.to_json))
    end
    suggest

    assert_equal MODEL, body["model"]
    assert_equal [ { "role" => "system", "content" => "framework" }, { "role" => "user", "content" => "item" } ], body["messages"]
    assert_equal({ "type" => "json_schema", "json_schema" => { "name" => "placement_suggestions", "strict" => true, "schema" => SCHEMA.deep_stringify_keys } },
                 body["response_format"])
    assert_equal "Bearer sk-gw", authorization
  end

  context "the token limit" do
    should "be max_tokens for the gateway and other servers" do
      assert_equal [ "max_tokens" ], limit_params(base_url: BASE, model: MODEL)
      assert_equal [ "max_tokens" ], limit_params(base_url: "https://llm.example.com/v1", model: "llama-3.3-70b")
    end

    should "be max_completion_tokens for OpenAI's own API and its reasoning models" do
      assert_equal [ "max_completion_tokens" ], limit_params(base_url: "https://api.openai.com/v1", model: "gpt-4.1")
      assert_equal [ "max_completion_tokens" ], limit_params(base_url: BASE, model: "openai/gpt-5")
      assert_equal [ "max_completion_tokens" ], limit_params(base_url: "https://llm.example.com/v1", model: "o3-mini")
    end

    should "cap a suggest request at 8,000 tokens" do
      body = nil
      @stubs.post("/v1/chat/completions") { |env| body = JSON.parse(env.body); json(completion({ suggestions: [] }.to_json)) }
      suggest

      assert_equal 8_000, body["max_tokens"]
    end
  end

  should "return the parsed suggestions, the reported model and the usage" do
    raw = [ { "capability_stable_id" => "c1", "level_ordinal" => 3, "valence" => "demonstrated", "confidence" => 0.9, "rationale" => "r" } ]
    @stubs.post("/v1/chat/completions") { json(completion({ suggestions: raw }.to_json)) }
    response = suggest

    assert_kind_of Ai::SuggestionResponse, response
    assert_equal raw, response.suggestions
    assert_equal MODEL, response.model
    assert_equal [ 200, 40 ], [ response.usage.input_tokens, response.usage.output_tokens ]
    assert_not response.refused?
  end

  should "flag a refusal, and a content filter, with no suggestions" do
    @stubs.post("/v1/chat/completions") { json(completion(nil, finish_reason: "stop", refusal: "I can't help with that.")) }
    response = suggest
    assert response.refused?
    assert_empty response.suggestions

    @stubs.post("/v1/chat/completions") { json(completion("{}", finish_reason: "content_filter")) }
    assert suggest.refused?
  end

  should "treat a truncated answer and unparseable content as no suggestions, not as an error" do
    [ completion('{"sugg', finish_reason: "length"), completion("Sure! Here you go."), completion(nil) ].each do |body|
      @stubs.post("/v1/chat/completions") { json(body) }
      response = suggest

      assert_empty response.suggestions
      assert_not response.refused?
    end
  end

  context "errors" do
    should "name a rejected key" do
      [ 401, 403 ].each do |status|
        @stubs.post("/v1/chat/completions") { json({ error: { message: "bad key sk-gw" } }, status: status) }
        error = assert_raises(Ai::Errors::AuthenticationError) { suggest }

        assert_match(/#{status}/, error.message)
        assert_no_match(/sk-gw/, error.message)
      end
    end

    should "carry Retry-After on a rate limit" do
      @stubs.post("/v1/chat/completions") { json({ error: "slow down" }, status: 429, headers: { "Retry-After" => "12" }) }
      error = assert_raises(Ai::Errors::RateLimitError) { suggest }
      assert_equal 12, error.retry_after

      @stubs.post("/v1/chat/completions") { json({ error: "slow down" }, status: 429) }
      assert_nil assert_raises(Ai::Errors::RateLimitError) { suggest }.retry_after
    end

    should "report other statuses with the status and a truncated body" do
      @stubs.post("/v1/chat/completions") { [ 502, {}, "x" * 2_000 ] }
      error = assert_raises(Ai::Errors::ApiError) { suggest }

      assert_equal 502, error.status
      assert_operator error.body.length, :<=, 500

      @stubs.post("/v1/chat/completions") { json({ error: "no such model" }, status: 404) }
      assert_equal 404, assert_raises(Ai::Errors::ApiError) { suggest }.status
    end

    should "report an unreachable endpoint with no status" do
      @stubs.post("/v1/chat/completions") { raise Faraday::ConnectionFailed, "refused" }
      assert_nil assert_raises(Ai::Errors::ApiError) { suggest }.status

      @stubs.post("/v1/chat/completions") { raise Faraday::TimeoutError }
      assert_nil assert_raises(Ai::Errors::ApiError) { suggest }.status
    end

    should "report a malformed response as an error: not JSON, not an object, no choices" do
      [ "<html>gateway</html>", "[1]", "{}", { choices: [] }.to_json, { choices: [ { finish_reason: "stop" } ] }.to_json ].each do |body|
        @stubs.post("/v1/chat/completions") { [ 200, {}, body ] }
        error = assert_raises(Ai::Errors::ApiError, body) { suggest }

        assert_equal 200, error.status
      end
    end
  end

  context "#ping" do
    should "send one line and return the reply" do
      seen = nil
      @stubs.post("/v1/chat/completions") do |env|
        seen = JSON.parse(env.body)
        json(completion(" ready "))
      end

      assert_equal "ready", @adapter.ping
      assert_equal [ { "role" => "user", "content" => Ai::OpenAiCompatible::Adapter::PING_PROMPT } ], seen["messages"]
      assert_not seen.key?("response_format")
    end

    should "raise a refusal, and the same errors as a request" do
      @stubs.post("/v1/chat/completions") { json(completion(nil, refusal: "no")) }
      assert_raises(Ai::Errors::RefusalError) { @adapter.ping }

      @stubs.post("/v1/chat/completions") { json({}, status: 401) }
      assert_raises(Ai::Errors::AuthenticationError) { @adapter.ping }
    end
  end

  context "the real connection" do
    should "refuse an endpoint on a private network before connecting" do
      adapter = Ai::OpenAiCompatible::Adapter.new(api_key: "sk-gw", base_url: "https://10.0.0.5/v1", model: MODEL)

      assert_raises(Ai::Errors::ConfigurationError) { adapter.ping }
    end

    should "need a key, an address and a model" do
      assert_raises(ArgumentError) { Ai::OpenAiCompatible::Adapter.new(api_key: "", base_url: BASE, model: MODEL) }
      assert_raises(ArgumentError) { Ai::OpenAiCompatible::Adapter.new(api_key: "k", base_url: "", model: MODEL) }
      assert_raises(ArgumentError) { Ai::OpenAiCompatible::Adapter.new(api_key: "k", base_url: BASE, model: "") }
    end
  end
end
