# frozen_string_literal: true

require "test_helper"
require_relative "../../support/placement_suggestion_fixture"

class Operations::Assessments::EvidenceSuggestionOperationsTest < ActiveSupport::TestCase
  include PlacementSuggestionFixture

  setup do
    build_placement_fixture
    @item = record_peer_feedback
    ActsAsTenant.with_tenant(@tenant) do
      @suggestion = create(:evidence_placement_suggestion, tenant: @tenant, item: @item,
        capability_stable_id: @ownership.stable_id, level_ordinal: 3, valence: "demonstrated", confidence: 0.82)
    end
  end

  teardown { ActsAsTenant.current_tenant = nil }

  def run_op(klass, as:, **params)
    ActsAsTenant.with_tenant(@tenant) { klass.call(context: context_for(as), params: params) }
  end

  def link_event
    Rails.configuration.event_store.read
      .stream(EventStreamNaming.person_development_stream(@alex.id, @framework_id, tenant: @tenant))
      .of_type([ PersonDevelopment::Events::EvidenceLinkAdded, PersonDevelopment::Events::EvidenceLinkRevalenced ])
      .backward.first
  end

  context "AcceptEvidenceSuggestion" do
    should "place the item on the suggested cell, attribute the link and record the decision" do
      result = run_op(Operations::Assessments::AcceptEvidenceSuggestion, as: @morgan, suggestion_id: @suggestion.id)

      assert_equal "accepted", result[:status]
      assert_equal [ { capability_stable_id: @ownership.stable_id, level_ordinal: 3, valence: "demonstrated" } ], result[:links]
      event = link_event
      assert_kind_of PersonDevelopment::Events::EvidenceLinkAdded, event
      assert_equal @suggestion.id, event.data[:via_suggestion_id]
      assert_equal @morgan.id, event.data[:linked_by_id]
      ActsAsTenant.with_tenant(@tenant) do
        @suggestion.reload
        assert_equal [ "accepted", @morgan.id ], [ @suggestion.status, @suggestion.decided_by_id ]
      end
    end

    should "record a different valence as an edited decision" do
      result = run_op(Operations::Assessments::AcceptEvidenceSuggestion, as: @alex,
        suggestion_id: @suggestion.id, valence: "strongly_demonstrated")

      assert_equal [ "edited", "strongly_demonstrated" ], [ result[:status], result[:valence] ]
      assert_equal "strongly_demonstrated", link_event.data[:valence]
    end

    should "reclassify instead when someone linked the cell in the meantime" do
      ActsAsTenant.with_tenant(@tenant) do
        PersonDevelopment::CommandHandler.new.add_evidence_link(@alex.id, @framework_id, @item.id,
          capability_stable_id: @ownership.stable_id, level_ordinal: 3, linked_by_id: @alex.id, valence: "growth_area")
      end

      run_op(Operations::Assessments::AcceptEvidenceSuggestion, as: @morgan, suggestion_id: @suggestion.id)

      event = link_event
      assert_kind_of PersonDevelopment::Events::EvidenceLinkRevalenced, event
      assert_equal [ "demonstrated", @suggestion.id ], [ event.data[:valence], event.data[:via_suggestion_id] ]
    end

    should "refuse someone who may not place this feedback" do
      assert_raises(Pundit::NotAuthorizedError) do
        run_op(Operations::Assessments::AcceptEvidenceSuggestion, as: @stranger, suggestion_id: @suggestion.id)
      end
      ActsAsTenant.with_tenant(@tenant) { assert @suggestion.reload.pending? }
    end

    should "refuse a suggestion already decided" do
      ActsAsTenant.with_tenant(@tenant) { @suggestion.decide!(status: "dismissed", by: @alex) }
      err = assert_raises(Operations::Base::ParameterError) do
        run_op(Operations::Assessments::AcceptEvidenceSuggestion, as: @alex, suggestion_id: @suggestion.id)
      end
      assert_match(/already dismissed/, err.message)
    end

    should "refuse a cell the person's role no longer reads" do
      ActsAsTenant.with_tenant(@tenant) { @suggestion.update!(capability_stable_id: @design_craft.stable_id) }
      assert_raises(Operations::Base::ParameterError) do
        run_op(Operations::Assessments::AcceptEvidenceSuggestion, as: @alex, suggestion_id: @suggestion.id)
      end
    end
  end

  context "DismissEvidenceSuggestion" do
    should "record the dismissal and the reason, without touching the item" do
      result = run_op(Operations::Assessments::DismissEvidenceSuggestion, as: @jordan,
        suggestion_id: @suggestion.id, reason: "This was about the release, not ownership")

      assert_equal [ "dismissed", "This was about the release, not ownership" ], [ result[:status], result[:dismiss_reason] ]
      ActsAsTenant.with_tenant(@tenant) { assert_empty EvidenceLink.active.where(evidence_id: @item.id) }
    end

    should "refuse someone who may not place this feedback" do
      assert_raises(Pundit::NotAuthorizedError) do
        run_op(Operations::Assessments::DismissEvidenceSuggestion, as: @stranger, suggestion_id: @suggestion.id)
      end
    end
  end

  context "EvidenceSuggestionsList" do
    should "list pending suggestions with names, confidence and provenance" do
      ActsAsTenant.with_tenant(@tenant) do
        create(:evidence_placement_suggestion, tenant: @tenant, item: @item, capability_stable_id: @collaboration.stable_id,
          status: "dismissed")
      end
      result = run_op(Operations::Assessments::EvidenceSuggestionsList, as: @morgan, assignment_id: @assignment.id)

      assert_equal [ @suggestion.id ], result[:suggestions].map { |s| s[:suggestion_id] }
      row = result[:suggestions].first
      assert_equal [ "Ownership", 0.82, "claude-opus-5-5" ], [ row[:capability_name], row[:confidence], row[:model] ]
    end

    should "let the author list one item's suggestions, but not the whole assessment" do
      result = run_op(Operations::Assessments::EvidenceSuggestionsList, as: @jordan,
        assignment_id: @assignment.id, evidence_id: @item.id)
      assert_equal 1, result[:suggestions].size

      assert_raises(Pundit::NotAuthorizedError) do
        run_op(Operations::Assessments::EvidenceSuggestionsList, as: @jordan, assignment_id: @assignment.id)
      end
    end
  end
end
