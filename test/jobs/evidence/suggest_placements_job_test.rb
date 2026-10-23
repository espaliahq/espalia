# frozen_string_literal: true

require "test_helper"
require_relative "../../support/placement_suggestion_fixture"

class Evidence::SuggestPlacementsJobTest < ActiveJob::TestCase
  include PlacementSuggestionFixture

  setup { build_placement_fixture }
  teardown { ActsAsTenant.current_tenant = nil }

  def suggestions_for(item, status: nil)
    ActsAsTenant.with_tenant(@tenant) do
      scope = EvidencePlacementSuggestion.for_evidence(item.id).order(:capability_stable_id, :level_ordinal)
      status ? scope.where(status: status).to_a : scope.to_a
    end
  end

  should "store the model's placements as pending suggestions, with model and prompt version" do
    item = record_peer_feedback
    with_fake_suggestion_model(proposals: [ proposal(@ownership), proposal(@collaboration, level_ordinal: 4, valence: "growth_area") ]) do
      Evidence::SuggestPlacementsJob.perform_now(item.id)
    end

    rows = suggestions_for(item)
    assert_equal 2, rows.size
    assert_equal %w[pending], rows.map(&:status).uniq
    row = rows.find { |r| r.capability_stable_id == @collaboration.stable_id }
    assert_equal [ 4, "growth_area" ], [ row.level_ordinal, row.valence ]
    assert_equal [ "anthropic", "claude-opus-5-5", Evidence::PlacementPrompt::VERSION ], [ row.provider, row.model, row.prompt_version ]
    assert_equal @alex.id, row.person_id
  end

  should "store a placement that comes with no rationale, as a decision model's do" do
    item = record_peer_feedback
    with_fake_suggestion_model(proposals: [ proposal(@ownership, confidence: 0.62, rationale: nil) ]) do
      Evidence::SuggestPlacementsJob.perform_now(item.id)
    end

    row = suggestions_for(item).sole
    assert_equal [ @ownership.stable_id, 0.62 ], [ row.capability_stable_id, row.confidence.to_f ]
    assert_nil row.rationale
  end

  should "drop a cell the role doesn't read, a level outside the window and a cell already linked" do
    item = record_peer_feedback(placed_on: @collaboration)
    hallucinated = Evidence::SuggestionModel::Proposal.new(capability_stable_id: SecureRandom.uuid_v7, level_ordinal: 3,
                                                           valence: "demonstrated", confidence: 0.9, rationale: "x")
    with_fake_suggestion_model(proposals: [ hallucinated, proposal(@design_craft), proposal(@ownership, level_ordinal: 5),
                                            proposal(@collaboration), proposal(@ownership) ]) do
      Evidence::SuggestPlacementsJob.perform_now(item.id)
    end

    assert_equal [ [ @ownership.stable_id, 3 ] ], suggestions_for(item).map(&:cell)
  end

  should "supersede the pending set on a rerun, reuse a superseded row and never reopen a dismissed cell" do
    item = record_peer_feedback
    with_fake_suggestion_model(proposals: [ proposal(@ownership), proposal(@collaboration) ]) do
      Evidence::SuggestPlacementsJob.perform_now(item.id)
    end
    ActsAsTenant.with_tenant(@tenant) do
      EvidencePlacementSuggestion.find_by(evidence_id: item.id, capability_stable_id: @collaboration.stable_id)
        .decide!(status: "dismissed", by: @alex)
    end

    fake = with_fake_suggestion_model(proposals: [ proposal(@ownership, confidence: 0.4), proposal(@collaboration) ]) do
      Evidence::SuggestPlacementsJob.perform_now(item.id)
    end

    ownership = suggestions_for(item).find { |r| r.capability_stable_id == @ownership.stable_id }
    assert_equal [ "pending", 0.4 ], [ ownership.status, ownership.confidence.to_f ]
    assert_equal "dismissed", suggestions_for(item).find { |r| r.capability_stable_id == @collaboration.stable_id }.status
    assert_not fake.prompts.last.open_cell?(@collaboration.stable_id, 3), "the dismissed cell is not offered again"
  end

  should "mark the old pending set superseded when the new answer is empty" do
    item = record_peer_feedback
    with_fake_suggestion_model(proposals: [ proposal(@ownership) ]) { Evidence::SuggestPlacementsJob.perform_now(item.id) }
    with_fake_suggestion_model(proposals: []) { Evidence::SuggestPlacementsJob.perform_now(item.id) }

    assert_equal %w[superseded], suggestions_for(item).map(&:status)
  end

  should "store nothing when the feedback was edited while the model was answering" do
    item = record_peer_feedback
    editing_model = Object.new
    editing_model.define_singleton_method(:model) { "claude-opus-5-5" }
    editing_model.define_singleton_method(:provider) { "anthropic" }
    tenant = @tenant
    editing_model.define_singleton_method(:suggest) do |prompt|
      ActsAsTenant.with_tenant(tenant) { EvidenceItem.where(id: prompt.item.id).update_all(content: "Edited meanwhile.") }
      [ Evidence::SuggestionModel::Proposal.new(capability_stable_id: prompt.cells.values.first[:capability_stable_id],
          level_ordinal: 3, valence: "demonstrated", confidence: 0.9, rationale: "x") ]
    end

    Evidence::SuggestionModel.stub(:configured?, true) do
      Evidence::SuggestionModel.stub(:new, ->(**) { editing_model }) { Evidence::SuggestPlacementsJob.perform_now(item.id) }
    end
    assert_empty suggestions_for(item)
  end

  should "do nothing when the tenant has suggestions off or without a key" do
    item = record_peer_feedback
    switch_suggestions(@tenant, false)
    fake = with_fake_suggestion_model(proposals: [ proposal(@ownership) ]) { Evidence::SuggestPlacementsJob.perform_now(item.id) }
    assert_empty fake.prompts

    switch_suggestions(@tenant, true)
    Evidence::SuggestionModel.stub(:configured?, false) do
      Evidence::SuggestionModel.stub(:new, ->(**) { flunk "the model must not be built without a key" }) do
        Evidence::SuggestPlacementsJob.perform_now(item.id)
      end
    end
    assert_empty suggestions_for(item)
  end

  should "suggest other cells for self feedback, never the one it was recorded on" do
    item = record_self_feedback
    fake = with_fake_suggestion_model(proposals: [ proposal(@ownership), proposal(@collaboration) ]) do
      Evidence::SuggestPlacementsJob.perform_now(item.id)
    end

    assert_equal [ [ @ownership.stable_id, 3 ] ], suggestions_for(item).map(&:cell)
    assert_equal %w[pending], suggestions_for(item).map(&:status)
    assert_includes fake.prompts.last.item_text, "Feedback from the person themselves"
    assert_not fake.prompts.last.open_cell?(@collaboration.stable_id, 3), "the cell it was recorded on is closed"
  end

  should "request one run per item a minute, and give the claim back when the enqueue fails" do
    item = record_peer_feedback
    clear_enqueued_jobs
    failing = Struct.new(:id) { def perform_later(*) = false }.new(1)
    Rails.stub(:cache, ActiveSupport::Cache::MemoryStore.new) do
      Evidence::SuggestPlacementsJob.stub(:set, ->(**) { failing }) do
        assert_not Evidence::SuggestPlacementsJob.request_run(item.id)
      end
      assert Evidence::SuggestPlacementsJob.request_run(item.id)
      assert_not Evidence::SuggestPlacementsJob.request_run(item.id)
    end
    assert_enqueued_jobs 1, only: Evidence::SuggestPlacementsJob
  end

  should "retry a rate limit and an outage, and give up quietly on a rejected request" do
    item = record_peer_feedback

    with_fake_suggestion_model(error: Evidence::SuggestionModel::RateLimited.new("429")) do
      assert_enqueued_with(job: Evidence::SuggestPlacementsJob) { Evidence::SuggestPlacementsJob.perform_now(item.id) }
    end
    with_fake_suggestion_model(error: Evidence::SuggestionModel::Unavailable.new("529")) do
      assert_enqueued_with(job: Evidence::SuggestPlacementsJob) { Evidence::SuggestPlacementsJob.perform_now(item.id) }
    end
    clear_enqueued_jobs
    with_fake_suggestion_model(error: Evidence::SuggestionModel::Rejected.new("400")) do
      assert_no_enqueued_jobs { Evidence::SuggestPlacementsJob.perform_now(item.id) }
    end
    assert_empty suggestions_for(item)
  end

  should "call the notification hook after storing a set" do
    item = record_peer_feedback
    hooked = []
    job = Evidence::SuggestPlacementsJob.new(item.id)
    job.define_singleton_method(:after_generate) { |i| hooked << i.id }
    with_fake_suggestion_model(proposals: [ proposal(@ownership) ]) { job.perform_now }
    assert_equal [ item.id ], hooked
  end

  context "for a tenant on an OpenAI-compatible gateway" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        @tenant.update_ai_model!(
          settings: { provider: "openai_compatible", base_url: "https://ai-gateway.vercel.sh/v1", model: "anthropic/claude-opus-5-5",
                      suggestions_enabled: true },
          api_key: "sk-gw"
        )
      end
    end

    should "get suggestions through the gateway, with names hidden in transit and restored in the rationale" do
      item = record_peer_feedback
      sent = nil
      stubs = Faraday::Adapter::Test::Stubs.new
      stubs.post("/v1/chat/completions") do |env|
        sent = JSON.parse(env.body)
        placeholder = sent["messages"].last["content"][/Person \d+/]
        answer = { suggestions: [
          { capability_stable_id: @ownership.stable_id, level_ordinal: 3, valence: "demonstrated", confidence: 0.8,
            rationale: "“#{placeholder} owned the outage follow-up” shows ownership." },
          { capability_stable_id: SecureRandom.uuid_v7, level_ordinal: 3, valence: "demonstrated", confidence: 0.9, rationale: "invented" }
        ] }
        [ 200, { "Content-Type" => "application/json" },
          { model: "anthropic/claude-opus-5-5", usage: { prompt_tokens: 1, completion_tokens: 1 },
            choices: [ { finish_reason: "stop", message: { content: answer.to_json } } ] }.to_json ]
      end
      connection = Faraday.new(url: "https://ai-gateway.vercel.sh/v1/") { |f| f.adapter :test, stubs }
      adapter = Ai::OpenAiCompatible::Adapter.new(api_key: "sk-gw", base_url: "https://ai-gateway.vercel.sh/v1",
                                                   model: "anthropic/claude-opus-5-5", connection: connection)

      Ai::ModelClient.stub(:for, adapter) { Evidence::SuggestPlacementsJob.perform_now(item.id) }

      assert_no_match(/Alex|Jordan|Morgan|Chen|Lee|Reid/, sent.to_json, "no name may leave the process")
      rows = suggestions_for(item)
      assert_equal 1, rows.size, "an id outside the candidates yields no row"
      assert_equal [ "openai_compatible", "anthropic/claude-opus-5-5", "pending" ], [ rows.first.provider, rows.first.model, rows.first.status ]
      assert_equal "“Alex owned the outage follow-up” shows ownership.", rows.first.rationale
    end

    should "do nothing for a tenant whose model is incomplete" do
      ActsAsTenant.with_tenant(@tenant) { @tenant.update_columns(ai_credentials: nil) }
      item = record_peer_feedback

      Ai::ModelClient.stub(:for, ->(*) { flunk "no client may be built without a key" }) do
        Evidence::SuggestPlacementsJob.perform_now(item.id)
      end
      assert_empty suggestions_for(item)
    end
  end

  context "for a tenant on Jev through the gateway" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        @tenant.update_ai_model!(
          settings: { provider: "typesafe_jev", base_url: AiModelConfig::VERCEL_AI_GATEWAY_URL, model: AiModelConfig::JEV_MODEL,
                      suggestions_enabled: true },
          api_key: "sk-gw"
        )
      end
    end

    should "store the likeliest cells with their probability as the confidence, no rationale and no names sent" do
      item = record_peer_feedback
      sent = nil
      stubs = Faraday::Adapter::Test::Stubs.new
      stubs.post("/v1/evaluate") do |env|
        sent = JSON.parse(env.body)
        answers = {
          placement: { type: "choice", choice: "#{@ownership.stable_id}|3",
                       probabilities: { "#{@ownership.stable_id}|3" => 0.71, "#{@collaboration.stable_id}|3" => 0.2, "none" => 0.09 } },
          valence: { type: "choice", choice: "demonstrated", probabilities: { "demonstrated" => 0.8, "strongly_demonstrated" => 0.2 } }
        }
        [ 200, { "Content-Type" => "application/json" },
          { model: "typesafe-ai/jev", answers: answers, usage: { inputTokens: 1200, outputTokens: 20 } }.to_json ]
      end
      connection = Faraday.new(url: "https://ai-gateway.vercel.sh/v1/") { |f| f.adapter :test, stubs }
      adapter = Ai::TypesafeJev::Adapter.new(api_key: "sk-gw", base_url: AiModelConfig::VERCEL_AI_GATEWAY_URL,
                                             model: AiModelConfig::JEV_MODEL, connection: connection)

      Ai::ModelClient.stub(:for, adapter) { Evidence::SuggestPlacementsJob.perform_now(item.id) }

      assert_equal "typesafe-ai/jev", sent["model"]
      assert_no_match(/Alex|Jordan|Morgan|Chen|Lee|Reid/, sent.to_json, "no name may leave the process")
      rows = suggestions_for(item).sort_by { |row| -row.confidence }
      assert_equal [ [ @ownership.stable_id, 0.71 ], [ @collaboration.stable_id, 0.2 ] ], rows.map { |r| [ r.capability_stable_id, r.confidence.to_f ] }
      assert_equal [ "typesafe_jev", "typesafe-ai/jev", Evidence::PlacementDecision::VERSION, "demonstrated", nil ],
                   [ rows.first.provider, rows.first.model, rows.first.prompt_version, rows.first.valence, rows.first.rationale ]
    end
  end
end
