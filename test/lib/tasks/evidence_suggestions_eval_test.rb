# frozen_string_literal: true

require "test_helper"
require "rake"
require Rails.root.join("lib/tasks/evidence_suggestions_eval")

# The eval itself calls a real model and is not run in CI. This keeps its
# plumbing and fixtures honest with the word-overlap baseline, and with a
# stubbed adapter standing in for the tenant's configured model.
class EvidenceSuggestionsEvalTest < ActiveSupport::TestCase
  # Answers every request with a valid cell at the middle level of the window.
  class MiddleCellAdapter
    attr_reader :requests

    def initialize = @requests = []
    def model = "fake/model"
    def provider = "openai_compatible"

    def suggest(system:, user:, schema:)
      @requests << { system: system, user: user }
      cell = schema.dig(:properties, :suggestions, :items, :properties)
      levels = cell.dig(:level_ordinal, :enum)
      raw = { "capability_stable_id" => cell.dig(:capability_stable_id, :enum).first, "level_ordinal" => levels[levels.size / 2],
              "valence" => "demonstrated", "confidence" => 0.5, "rationale" => "stub" }
      Ai::SuggestionResponse.new(suggestions: [ raw ], model: model,
                                 usage: Ai::SuggestionResponse::Usage.new(input_tokens: 1, output_tokens: 1), refused: false)
    end
  end

  should "score every fixture and leave nothing behind" do
    report = EvidenceSuggestionsEval.new(model: EvidenceSuggestionsEval::BaselineModel.new).run

    assert_equal 30, report[:items]
    assert_equal [ 27, 3 ], [ report[:placeable], report[:uncovered] ]
    assert_equal Evidence::PlacementPrompt::VERSION, report[:prompt_version]
    assert_equal [ "baseline", "baseline" ], [ report[:provider], report[:model] ]
    assert_operator report[:cell_match_top], :>, 0
    assert_not Tenant.exists?([ "slug LIKE ?", "suggestion-eval-%" ])
  end

  context ".model_for" do
    should "run a tenant's configured adapter through the real pipeline" do
      tenant = create(:tenant, :with_ai_model, slug: "acme")
      adapter = MiddleCellAdapter.new

      model = Ai::ModelClient.stub(:for, ->(t, model: nil) { assert_equal tenant, t; adapter }) do
        EvidenceSuggestionsEval.model_for(slug: "acme")
      end
      report = EvidenceSuggestionsEval.new(model: model).run

      assert_equal 30, report[:items]
      assert_equal 30, adapter.requests.size
      assert_equal [ "openai_compatible", "fake/model" ], [ report[:provider], report[:model] ]
      assert_operator report[:cell_match_any], :>, 0, "the stubbed answers reach the scoring"
      assert_not Tenant.exists?([ "slug LIKE ?", "suggestion-eval-%" ])
    end

    should "pass a MODEL override to the adapter" do
      create(:tenant, :with_ai_model, slug: "acme")
      seen = nil

      Ai::ModelClient.stub(:for, ->(_tenant, model: nil) { seen = model; MiddleCellAdapter.new }) do
        EvidenceSuggestionsEval.model_for(slug: "acme", model: "claude-haiku-5-5")
      end

      assert_equal "claude-haiku-5-5", seen
    end

    should "say what is missing instead of calling anything" do
      create(:tenant, slug: "bare")

      assert_match(/Name a tenant/, assert_raises(ArgumentError) { EvidenceSuggestionsEval.model_for(slug: nil) }.message)
      assert_match(/No tenant with the slug "nope"/, assert_raises(ArgumentError) { EvidenceSuggestionsEval.model_for(slug: "nope") }.message)
      assert_match(/has no AI model configured/, assert_raises(ArgumentError) { EvidenceSuggestionsEval.model_for(slug: "bare") }.message)
    end
  end

  context "the rake task" do
    setup do
      Rails.application.load_tasks if Rake::Task.tasks.empty?
      @task = Rake::Task["evidence:suggestions:eval"]
      @task.reenable
    end

    should "abort with the reason when the tenant has no model" do
      create(:tenant, slug: "bare")

      error = assert_raises(SystemExit) { capture_io { @task.invoke("bare") } }
      assert_equal 1, error.status
    end

    should "run the baseline without a tenant" do
      out, = capture_io do
        ENV["SUGGESTION_MODEL"] = "baseline"
        @task.invoke
      ensure
        ENV.delete("SUGGESTION_MODEL")
      end

      assert_includes out, "baseline baseline · 30 items"
    end
  end
end
