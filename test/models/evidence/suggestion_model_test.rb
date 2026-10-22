# frozen_string_literal: true

require "test_helper"

# What the placement code asks of the model and gets back, with the adapter
# faked: pseudonymising on the way out, restoring on the way in, and turning
# the adapter's errors into the ones the job chooses a policy for.
class Evidence::SuggestionModelTest < ActiveSupport::TestCase
  Prompt = Struct.new(:framework_text, :item_text, :schema)

  class FakeAdapter
    attr_reader :calls

    def initialize(suggestions: [], error: nil, refused: false)
      @suggestions = suggestions
      @error = error
      @refused = refused
      @calls = []
    end

    def model = "fake-model"
    def provider = "openai_compatible"

    def suggest(system:, user:, schema:)
      @calls << { system: system, user: user, schema: schema }
      raise @error if @error

      Ai::SuggestionResponse.new(suggestions: @suggestions, model: model,
                                 usage: Ai::SuggestionResponse::Usage.new(input_tokens: 10, output_tokens: 5), refused: @refused)
    end
  end

  class FakeDecider
    attr_reader :calls

    def initialize(error: nil)
      @error = error
      @calls = []
    end

    def model = "typesafe-ai/jev"
    def provider = "typesafe_jev"

    def decide(state:, questions:)
      @calls << { state: state, questions: questions }
      raise @error if @error

      Ai::DecisionResponse.new(answers: {}, model: model, usage: Ai::SuggestionResponse::Usage.new(input_tokens: 1, output_tokens: 1))
    end
  end

  setup do
    @tenant = create(:tenant, :with_ai_model)
    ActsAsTenant.with_tenant(@tenant) do
      create(:person, tenant: @tenant, name: "Alex Chen")
      create(:person, tenant: @tenant, name: "Anna Reid")
    end
  end

  def run_model(adapter, tenant: @tenant, text: "Alex Chen led the review; Anna wrote it up.", framework: "Framework for Alex Chen.")
    model = Evidence::SuggestionModel.new(tenant: tenant, adapter: adapter)
    [ model.suggest(Prompt.new(framework, text, { type: "object" })), adapter.calls.first ]
  end

  def raw(**overrides)
    { "capability_stable_id" => "c1", "level_ordinal" => 3, "valence" => "demonstrated", "confidence" => 0.8,
      "rationale" => "“Person 1 led the review” shows ownership." }.merge(overrides.stringify_keys)
  end

  should "report the adapter's provider and model, for the row" do
    model = Evidence::SuggestionModel.new(tenant: @tenant, adapter: FakeAdapter.new)

    assert_equal [ "openai_compatible", "fake-model" ], [ model.provider, model.model ]
  end

  context "pseudonymisation" do
    should "swap names for placeholders in both texts and the schema untouched" do
      _, call = run_model(FakeAdapter.new)

      assert_equal "Framework for Person 1.", call[:system]
      assert_equal "Person 1 led the review; Person 2 wrote it up.", call[:user]
      assert_equal({ type: "object" }, call[:schema])
    end

    should "leave first names alone in the framework text, where they are only words" do
      ActsAsTenant.with_tenant(@tenant) { create(:person, tenant: @tenant, name: "Will Hart") }
      _, call = run_model(FakeAdapter.new, text: "Will Hart will present.", framework: "Will Hart will review; will deliver.")

      assert_match(/\APerson \d+ will review; will deliver\.\z/, call[:system])
      assert_match(/\APerson \d+ Person \d+ present\.\z/, call[:user], "the feedback itself gets first names too")
    end

    should "drop a chat placement that came without the rationale it was asked for" do
      blank, *kept = [ raw(rationale: "  ") ] + %w[c2 c3 c4].map { |id| raw(capability_stable_id: id) }
      proposals, = run_model(FakeAdapter.new(suggestions: [ blank, *kept ]))

      assert_equal %w[c2 c3 c4], proposals.map(&:capability_stable_id), "a blank one does not use up a place"
    end

    should "put the names back in the rationales that come back" do
      proposals, = run_model(FakeAdapter.new(suggestions: [ raw ]))

      assert_equal "“Alex Chen led the review” shows ownership.", proposals.first.rationale
    end

    should "send names as written when the tenant turned it off" do
      @tenant.update!(ai_config: AiModelConfig.new(@tenant.ai_config.attributes.merge("pseudonymise_names" => false)))
      proposals, call = run_model(FakeAdapter.new(suggestions: [ raw(rationale: "Person 1 is left alone.") ]))

      assert_equal "Alex Chen led the review; Anna wrote it up.", call[:user]
      assert_equal "Person 1 is left alone.", proposals.first.rationale
    end

    should "keep another tenant's people out of the mapping" do
      other = create(:tenant, :with_ai_model)
      ActsAsTenant.with_tenant(other) { create(:person, tenant: other, name: "Morgan Park") }
      _, call = run_model(FakeAdapter.new, tenant: other, text: "Alex Chen met Morgan Park.")

      assert_equal "Alex Chen met Person 1.", call[:user]
    end
  end

  should "return at most three proposals, confidence clamped, rationale stripped" do
    suggestions = Array.new(4) { |i| raw(capability_stable_id: "c#{i}", confidence: 1.4, rationale: " plain ") }
    proposals, = run_model(FakeAdapter.new(suggestions: suggestions))

    assert_equal 3, proposals.size
    assert_equal [ 1.0, "plain" ], [ proposals.first.confidence, proposals.first.rationale ]
    assert_kind_of Evidence::SuggestionModel::Proposal, proposals.first
  end

  should "treat a refusal as no suggestions" do
    proposals, = run_model(FakeAdapter.new(refused: true))

    assert_empty proposals
  end

  should "turn the adapter's errors into ones the job can choose a policy for" do
    {
      Ai::Errors::RateLimitError.new(retry_after: 3) => Evidence::SuggestionModel::RateLimited,
      Ai::Errors::AuthenticationError.new("key rejected") => Evidence::SuggestionModel::Rejected,
      Ai::Errors::ApiError.new(status: 400, body: "bad") => Evidence::SuggestionModel::Rejected,
      Ai::Errors::ApiError.new(status: 404, body: "no model") => Evidence::SuggestionModel::Rejected,
      Ai::Errors::ConfigurationError.new("private address") => Evidence::SuggestionModel::Rejected,
      Ai::Errors::ApiError.new(status: 408, body: "slow") => Evidence::SuggestionModel::Unavailable,
      Ai::Errors::ApiError.new(status: 503, body: "down") => Evidence::SuggestionModel::Unavailable,
      Ai::Errors::ApiError.new(status: nil, message: "unreachable") => Evidence::SuggestionModel::Unavailable,
      Ai::Errors::ApiError.new(status: 200, message: "not JSON") => Evidence::SuggestionModel::Unavailable
    }.each do |failure, expected|
      assert_raises(expected, failure.message) { run_model(FakeAdapter.new(error: failure)) }
    end
  end

  context ".configured?" do
    should "follow the tenant's own model and key" do
      assert Evidence::SuggestionModel.configured?(@tenant)
      assert_not Evidence::SuggestionModel.configured?(create(:tenant))
    end
  end

  context "with a decision model" do
    should "ask the decision questions instead of the chat prompt" do
      decision = Struct.new(:state, :questions) { def proposals(_response, limit:) = [ limit ] }.new({ feedback: "x" }, { q: 1 })
      adapter = FakeDecider.new
      Evidence::PlacementDecision.stub(:new, decision) do
        assert_equal [ Evidence::SuggestionModel::MAX_SUGGESTIONS ], Evidence::SuggestionModel.new(tenant: @tenant, adapter: adapter).suggest(Object.new)
      end
      assert_equal [ { state: { feedback: "x" }, questions: { q: 1 } } ], adapter.calls
    end

    should "map its errors like any other adapter's" do
      decision = Struct.new(:state, :questions).new("s", {})
      Evidence::PlacementDecision.stub(:new, decision) do
        model = Evidence::SuggestionModel.new(tenant: @tenant, adapter: FakeDecider.new(error: Ai::Errors::RateLimitError.new))
        assert_raises(Evidence::SuggestionModel::RateLimited) { model.suggest(Object.new) }
      end
    end
  end
end
