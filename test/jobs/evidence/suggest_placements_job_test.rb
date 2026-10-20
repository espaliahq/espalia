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
    assert_equal [ "claude-opus-5-5", Evidence::PlacementPrompt::VERSION ], [ row.model, row.prompt_version ]
    assert_equal @alex.id, row.person_id
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

  should "do nothing when the tenant has suggestions off, without a key, or for self feedback" do
    item = record_peer_feedback
    ActsAsTenant.with_tenant(@tenant) { @tenant.update!(evidence_suggestions_enabled: false) }
    fake = with_fake_suggestion_model(proposals: [ proposal(@ownership) ]) { Evidence::SuggestPlacementsJob.perform_now(item.id) }
    assert_empty fake.prompts

    ActsAsTenant.with_tenant(@tenant) { @tenant.update!(evidence_suggestions_enabled: true) }
    Evidence::SuggestionModel.stub(:configured?, false) do
      Evidence::SuggestionModel.stub(:new, ->(**) { flunk "the model must not be built without a key" }) do
        Evidence::SuggestPlacementsJob.perform_now(item.id)
      end
    end

    ActsAsTenant.with_tenant(@tenant) { item.update_columns(source: "self") }
    fake = with_fake_suggestion_model(proposals: [ proposal(@ownership) ]) { Evidence::SuggestPlacementsJob.perform_now(item.id) }
    assert_empty fake.prompts
    assert_empty suggestions_for(item)
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
end
