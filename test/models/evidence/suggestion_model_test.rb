# frozen_string_literal: true

require "test_helper"

# The SDK boundary: what goes out and what comes back. The client is stubbed;
# nothing here reaches the network.
class Evidence::SuggestionModelTest < ActiveSupport::TestCase
  Prompt = Struct.new(:framework_text, :item_text, :schema)
  Block = Struct.new(:type, :text)
  Message = Struct.new(:stop_reason, :content)

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

  def run_model(result)
    messages = FakeMessages.new(result)
    model = Evidence::SuggestionModel.new
    model.instance_variable_set(:@client, FakeClient.new(messages))
    [ model.suggest(Prompt.new("framework", "item", { type: "object" })), messages.params ]
  end

  def answer(json, stop_reason: :end_turn)
    Message.new(stop_reason, [ Block.new(:thinking, nil), Block.new(:text, json) ])
  end

  def status_error(klass, status)
    klass.new(url: URI("https://api.anthropic.com/v1/messages"), status: status, headers: {}, body: nil,
              request: nil, response: nil, message: "boom")
  end

  should "cache the framework text, put the item last, and ask for low effort and the schema" do
    _, params = run_model(answer({ suggestions: [] }.to_json))

    assert_equal "claude-opus-5-5", params[:model]
    assert_equal [ { type: "text", text: "framework", cache_control: { type: "ephemeral" } } ], params[:system_]
    assert_equal [ { role: "user", content: "item" } ], params[:messages]
    assert_equal :low, params.dig(:output_config, :effort)
    assert_equal({ type: :json_schema, schema: { type: "object" } }, params.dig(:output_config, :format_))
    assert_not params.key?(:thinking), "Opus 5.5 thinks adaptively; budgets and disabling are rejected"
  end

  should "return at most three proposals, confidence clamped" do
    raw = Array.new(4) { |i| { capability_stable_id: "c#{i}", level_ordinal: 3, valence: "demonstrated", confidence: 1.4, rationale: " r " } }
    proposals, = run_model(answer({ suggestions: raw }.to_json))

    assert_equal 3, proposals.size
    assert_equal 1.0, proposals.first.confidence
    assert_equal "r", proposals.first.rationale
  end

  should "treat a refusal, a truncated answer and unparseable text as no suggestions" do
    assert_equal [], run_model(answer("{}", stop_reason: :refusal)).first
    assert_equal [], run_model(answer('{"sugg', stop_reason: :max_tokens)).first
    assert_equal [], run_model(answer("not json")).first
  end

  should "turn the SDK's errors into ones the job can choose a policy for" do
    assert_raises(Evidence::SuggestionModel::RateLimited) { run_model(status_error(Anthropic::Errors::RateLimitError, 429)) }
    assert_raises(Evidence::SuggestionModel::Unavailable) { run_model(status_error(Anthropic::Errors::InternalServerError, 529)) }
    assert_raises(Evidence::SuggestionModel::Rejected) { run_model(status_error(Anthropic::Errors::BadRequestError, 400)) }
    assert_raises(Evidence::SuggestionModel::Unavailable) do
      run_model(Anthropic::Errors::APIConnectionError.new(url: URI("https://api.anthropic.com"), request: nil))
    end
  end
end
