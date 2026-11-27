# frozen_string_literal: true

require "test_helper"
require_relative "../support/placement_suggestion_fixture"

# Forgetting the person the feedback is about closes their pending suggestions
# inside the erase, keeps the ones already decided, and refuses any new ones
# ([#590](https://github.com/espaliahq/espalia/issues/590)).
class ForgottenPersonSuggestionsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include PlacementSuggestionFixture

  PROVENANCE = { provider: "espalia", effective_on: "2020-01-01" }.freeze

  setup do
    build_placement_fixture
    @item = record_peer_feedback
    with_fake_suggestion_model(proposals: [ proposal(@ownership), proposal(@collaboration), proposal(@ownership, level_ordinal: 4) ]) do
      Evidence::SuggestPlacementsJob.perform_now(@item.id)
    end
    ActsAsTenant.with_tenant(@tenant) do
      suggestions = EvidencePlacementSuggestion.where(evidence_id: @item.id)
      @accepted = suggestions.find_by!(capability_stable_id: @ownership.stable_id, level_ordinal: 3)
      @dismissed = suggestions.find_by!(capability_stable_id: @collaboration.stable_id)
      @pending = suggestions.find_by!(capability_stable_id: @ownership.stable_id, level_ordinal: 4)
    end
  end

  def stream_post(path, params: {})
    post path, params: params, headers: { "Accept" => "text/vnd.turbo-stream.html, text/html" }
  end

  def decide_then_forget
    sign_in @morgan_user
    stream_post accept_evidence_placement_suggestion_path(@accepted)
    stream_post dismiss_evidence_placement_suggestion_path(@dismissed), params: { reason: "Not about this" }

    TenantSettings::CommandHandler.new(@tenant).enable_scheduled_forgetting { 1 }
    ActsAsTenant.with_tenant(@tenant) do
      handler = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
      handler.sync_person(@alex.id, **PROVENANCE, employment_status: "employed")
      handler.sync_person(@alex.id, **PROVENANCE, employment_status: "left", left_on: "2010-01-01")
    end
    OrgGraph::Forgetting.new(@tenant).forget_due
    assert @alex.reload.forgotten?
  end

  def statuses = ActsAsTenant.with_tenant(@tenant) { [ @accepted, @dismissed, @pending ].map { it.reload.status } }

  should "close only the pending suggestion, and keep the decisions made before the erase" do
    decide_then_forget

    assert_equal %w[accepted dismissed closed], statuses
  end

  should "list nothing for the forgotten person over MCP" do
    decide_then_forget
    payload = ActsAsTenant.with_tenant(@tenant) do
      Operations::Assessments::EvidenceSuggestionsList.call(context: context_for(@morgan),
                                                            params: { assignment_id: @assignment.id })
    end

    assert_empty payload[:suggestions]
  end

  should "store no new suggestions once the person is forgotten" do
    decide_then_forget
    with_fake_suggestion_model(proposals: [ proposal(@collaboration, level_ordinal: 4) ]) do
      Evidence::SuggestPlacementsJob.perform_now(@item.id)
    end

    assert_equal 3, ActsAsTenant.with_tenant(@tenant) { EvidencePlacementSuggestion.where(evidence_id: @item.id).count }
    assert_raises(PersonDevelopment::SuggestionWrites::Forgotten) do
      ActsAsTenant.with_tenant(@tenant) do
        PersonDevelopment::SuggestionWrites.with_aggregate(@alex.id, @framework_id, evidence_ids: [ @item.id ]) { flunk }
      end
    end
  end
end
