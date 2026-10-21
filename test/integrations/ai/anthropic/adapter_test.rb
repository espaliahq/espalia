# frozen_string_literal: true

require "test_helper"

# The gem boundary: what goes out and what comes back. The client is a fake;
# nothing here reaches the network.
class Ai::Anthropic::AdapterTest < ActiveSupport::TestCase
  Block = Struct.new(:type, :text)
  Usage = Struct.new(:input_tokens, :output_tokens)
  Message = Struct.new(:stop_reason, :content, :model, :usage)

  class FakeMessages
    attr_reader :params

    def initialize(result) = @result = result

    def create(**params)
      @params = params
      raise @result if @result.is_a?(Exception)

      @result
    end
  end

  FakeClient = Struct.new(:messages)

  SCHEMA = { type: "object" }.freeze

  def adapter_for(result, **options)
    messages = FakeMessages.new(result)
    adapter = Ai::Anthropic::Adapter.new(api_key: "sk-test", client: FakeClient.new(messages), **options)
    [ adapter, messages ]
  end

  def answer(json, stop_reason: :end_turn)
    Message.new(stop_reason, [ Block.new(:thinking, nil), Block.new(:text, json) ], "claude-opus-5-5", Usage.new(120, 30))
  end

  def status_error(klass, status, headers: {})
    klass.new(url: URI("https://api.anthropic.com/v1/messages"), status: status, headers: headers, body: nil,
              request: nil, response: nil, message: "boom")
  end

  def suggest(adapter) = adapter.suggest(system: "framework", user: "item", schema: SCHEMA)

  should "cache the system text, put the item last, and ask for the schema at the configured effort" do
    adapter, messages = adapter_for(answer({ suggestions: [] }.to_json), effort: "medium")
    suggest(adapter)
    params = messages.params

    assert_equal "claude-opus-5-5", params[:model]
    assert_equal [ { type: "text", text: "framework", cache_control: { type: "ephemeral" } } ], params[:system_]
    assert_equal [ { role: "user", content: "item" } ], params[:messages]
    assert_equal :medium, params.dig(:output_config, :effort)
    assert_equal({ type: :json_schema, schema: SCHEMA }, params.dig(:output_config, :format_))
    assert_not params.key?(:thinking), "Opus 5.5 thinks adaptively; budgets and disabling are rejected"
    assert_not params.key?(:tool_choice), "forced tool use is rejected"
  end

  should "send no effort at all when it is blank, for models that reject it" do
    adapter, messages = adapter_for(answer("{}"), effort: "")
    suggest(adapter)
    assert_equal [ :format_ ], messages.params[:output_config].keys

    adapter, messages = adapter_for(Message.new(:end_turn, [ Block.new(:text, "ready") ], "m", nil), effort: nil)
    adapter.ping
    assert_equal({}, messages.params[:output_config])
  end

  should "default to low effort and the Opus 5.5 model, and use a configured model" do
    adapter, messages = adapter_for(answer("{}"))
    suggest(adapter)
    assert_equal [ "claude-opus-5-5", :low ], [ messages.params[:model], messages.params.dig(:output_config, :effort) ]

    adapter, messages = adapter_for(answer("{}"), model: "claude-haiku-5-5")
    suggest(adapter)
    assert_equal "claude-haiku-5-5", messages.params[:model]
  end

  should "return the parsed suggestions, the model and the usage" do
    raw = [ { capability_stable_id: "c1", level_ordinal: 3, valence: "demonstrated", confidence: 0.9, rationale: "r" } ]
    adapter, = adapter_for(answer({ suggestions: raw }.to_json))
    response = suggest(adapter)

    assert_kind_of Ai::SuggestionResponse, response
    assert_equal [ raw.first.stringify_keys ], response.suggestions
    assert_equal "claude-opus-5-5", response.model
    assert_equal [ 120, 30 ], [ response.usage.input_tokens, response.usage.output_tokens ]
    assert_not response.refused?
  end

  should "flag a refusal and return no suggestions" do
    response = suggest(adapter_for(answer("{}", stop_reason: :refusal)).first)

    assert response.refused?
    assert_empty response.suggestions
  end

  should "treat a truncated answer and unparseable text as no suggestions, not as an error" do
    [ answer('{"sugg', stop_reason: :max_tokens), answer("not json"), answer("[1, 2]"), answer({ suggestions: "x" }.to_json) ].each do |message|
      response = suggest(adapter_for(message).first)

      assert_empty response.suggestions
      assert_not response.refused?
    end
  end

  should "drop suggestions that are not objects" do
    response = suggest(adapter_for(answer({ suggestions: [ 1, "x", { "a" => 1 } ] }.to_json)).first)

    assert_equal [ { "a" => 1 } ], response.suggestions
  end

  context "errors" do
    should "name a rejected key" do
      [ [ Anthropic::Errors::AuthenticationError, 401 ], [ Anthropic::Errors::PermissionDeniedError, 403 ] ].each do |klass, status|
        error = assert_raises(Ai::Errors::AuthenticationError) { suggest(adapter_for(status_error(klass, status)).first) }
        assert_match(/#{status}/, error.message)
      end
    end

    should "carry Retry-After on a rate limit" do
      error = assert_raises(Ai::Errors::RateLimitError) do
        suggest(adapter_for(status_error(Anthropic::Errors::RateLimitError, 429, headers: { "retry-after" => "17" })).first)
      end
      assert_equal 17, error.retry_after

      error = assert_raises(Ai::Errors::RateLimitError) { suggest(adapter_for(status_error(Anthropic::Errors::RateLimitError, 429)).first) }
      assert_nil error.retry_after
    end

    should "report other statuses with the status" do
      error = assert_raises(Ai::Errors::ApiError) { suggest(adapter_for(status_error(Anthropic::Errors::InternalServerError, 529)).first) }
      assert_equal 529, error.status

      error = assert_raises(Ai::Errors::ApiError) { suggest(adapter_for(status_error(Anthropic::Errors::BadRequestError, 400)).first) }
      assert_equal 400, error.status
    end

    should "report a dropped connection and a timeout with no status" do
      [ Anthropic::Errors::APIConnectionError.new(url: URI("https://api.anthropic.com"), request: nil),
        Anthropic::Errors::APITimeoutError.new(url: URI("https://api.anthropic.com"), request: nil) ].each do |failure|
        error = assert_raises(Ai::Errors::ApiError) { suggest(adapter_for(failure).first) }
        assert_nil error.status
      end
    end
  end

  context "#ping" do
    should "send one line and return the reply" do
      adapter, messages = adapter_for(Message.new(:end_turn, [ Block.new(:text, " ready ") ], "claude-opus-5-5", Usage.new(5, 2)))

      assert_equal "ready", adapter.ping
      assert_equal [ { role: "user", content: Ai::Anthropic::Adapter::PING_PROMPT } ], messages.params[:messages]
    end

    should "raise a refusal, and the same errors as a request" do
      adapter, = adapter_for(Message.new(:refusal, [], "claude-opus-5-5", nil))
      assert_raises(Ai::Errors::RefusalError) { adapter.ping }

      adapter, = adapter_for(status_error(Anthropic::Errors::AuthenticationError, 401))
      assert_raises(Ai::Errors::AuthenticationError) { adapter.ping }
    end
  end

  context "the real client" do
    should "be built with the tenant's key and address, never the environment's" do
      built = nil
      adapter = Ai::Anthropic::Adapter.new(api_key: "sk-tenant", base_url: "https://proxy.example.com")
      Ai::HostGuard.stub(:check!, nil) do
        Anthropic::Client.stub(:new, ->(**options) { built = options; FakeClient.new(FakeMessages.new(answer("{}"))) }) do
          suggest(adapter)
        end
      end

      assert_equal "sk-tenant", built[:api_key]
      assert_equal "https://proxy.example.com", built[:base_url]
      assert_equal 0, built[:max_retries]
    end

    should "guard every leg of a redirect, not only the saved address" do
      built = nil
      adapter = Ai::Anthropic::Adapter.new(api_key: "sk-tenant", base_url: "https://proxy.example.com")
      Ai::HostGuard.stub(:check!, nil) do
        Anthropic::Client.stub(:new, ->(**options) { built = options; FakeClient.new(FakeMessages.new(answer("{}"))) }) { suggest(adapter) }
      end
      guard = built[:middleware].first
      seen = []
      leg = Struct.new(:url).new(URI("https://elsewhere.example.com/v1/messages"))

      Ai::HostGuard.stub(:check!, ->(url) { seen << url }) { assert_equal :sent, guard.call(leg, ->(_) { :sent }) }
      assert_equal [ "https://elsewhere.example.com/v1/messages" ], seen

      private_leg = Struct.new(:url).new(URI("https://127.1/v1/messages"))
      assert_raises(Ai::Errors::ConfigurationError) { guard.call(private_leg, ->(_) { flunk "must not be sent" }) }
    end

    should "not add the guard for the Anthropic API itself" do
      built = nil
      adapter = Ai::Anthropic::Adapter.new(api_key: "sk-tenant")
      Anthropic::Client.stub(:new, ->(**options) { built = options; FakeClient.new(FakeMessages.new(answer("{}"))) }) { suggest(adapter) }

      assert_nil built[:middleware]
    end

    should "refuse an endpoint on a private network before connecting" do
      adapter = Ai::Anthropic::Adapter.new(api_key: "sk-tenant", base_url: "https://10.0.0.5")

      assert_raises(Ai::Errors::ConfigurationError) { suggest(adapter) }
    end

    should "need a key" do
      assert_raises(ArgumentError) { Ai::Anthropic::Adapter.new(api_key: "") }
    end
  end
end
