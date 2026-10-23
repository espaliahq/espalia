# frozen_string_literal: true

require "test_helper"
require_relative "../support/placement_suggestion_fixture"

# Placement suggestions on the hub: who sees them, deciding them in place, and
# "Adjust" through the evidence modal.
class EvidencePlacementSuggestionsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include ActiveJob::TestHelper
  include PlacementSuggestionFixture

  setup do
    build_placement_fixture
    @item = record_peer_feedback
    ActsAsTenant.with_tenant(@tenant) do
      @ownership_suggestion = create(:evidence_placement_suggestion, tenant: @tenant, item: @item,
        capability_stable_id: @ownership.stable_id, level_ordinal: 3, valence: "demonstrated", confidence: 0.82)
      @collaboration_suggestion = create(:evidence_placement_suggestion, tenant: @tenant, item: @item,
        capability_stable_id: @collaboration.stable_id, level_ordinal: 4, valence: "growth_area", confidence: 0.4,
        rationale: "“kept everyone informed” speaks to collaboration.")
    end
  end


  def stream_post(path, params: {})
    post path, params: params, headers: { "Accept" => "text/vnd.turbo-stream.html, text/html" }
  end

  def links
    ActsAsTenant.with_tenant(@tenant) { EvidenceLink.active.where(evidence_id: @item.id).pluck(:capability_stable_id, :level_ordinal) }
  end

  # The ownership suggestion kept through "Adjust", after any rows picked by hand.
  def save_adjusted(valence: "demonstrated", picked: [])
    patch evidence_item_path(@item), params: { evidence: {
      evidence_id: @item.id, assignment_id: @assignment.id,
      desired_links: picked + [ "#{@ownership.stable_id}|3" ],
      link_valences: (picked + [ "#{@ownership.stable_id}|3" ]).index_with(valence),
      suggestion_ids: [ @ownership_suggestion.id ], staged_suggestion_ids: [ @ownership_suggestion.id ]
    } }
  end

  context "the hub" do
    should "list suggestions under the item for the person it is about, most confident first" do
      sign_in @alex_user
      get evidence_hub_path

      assert_select "##{Views::Evidence::PlacementSuggestions.dom_id_for(@item.id)} li[data-suggestion-id]", count: 2
      rows = css_select("##{Views::Evidence::PlacementSuggestions.dom_id_for(@item.id)} li[data-suggestion-id]")
      assert_equal [ @ownership_suggestion.id, @collaboration_suggestion.id ], rows.map { |r| r["data-suggestion-id"] }
      assert_select "li[data-suggestion-id='#{@ownership_suggestion.id}']", text: /Ownership · E3.*Demonstrates.*82% confident/m
      assert_select "##{Views::Evidence::PlacementSuggestions.status_id_for(@item.id)}[role='status']"
    end

    should "show them to the manager and the author too, but not to someone outside the item" do
      [ @morgan_user, @jordan_user ].each do |user|
        sign_in user
        get evidence_hub_path
        assert_select "li[data-suggestion-id='#{@ownership_suggestion.id}']", 1, "#{user.email} should see it"
        sign_out user
      end

      sign_in @stranger_user
      get evidence_hub_path
      assert_select "li[data-suggestion-id]", count: 0
    end

    should "list a placed item's extra suggestions under May fit elsewhere too" do
      placed = record_peer_feedback(content: "Placed already.", placed_on: @collaboration)
      ActsAsTenant.with_tenant(@tenant) do
        create(:evidence_placement_suggestion, tenant: @tenant, item: placed, capability_stable_id: @ownership.stable_id)
      end

      sign_in @morgan_user
      get evidence_hub_path
      assert_select "#suggested-placements ##{EvidenceItem.dom_id(placed.id)} li[data-suggestion-id]", count: 1
    end

    should "show a requested response's suggestions once, on its response card" do
      request_id = SecureRandom.uuid_v7
      response_id = SecureRandom.uuid_v7
      ActsAsTenant.with_tenant(@tenant) do
        handler = PersonDevelopment::CommandHandler.new
        handler.request_evidence(@alex.id, @framework_id, request_id, requested_by_id: @morgan.id,
          requestee_person_id: @jordan.id, capability_stable_id: @collaboration.stable_id, level_ordinal: 3)
        handler.record_evidence_for_request(@alex.id, @framework_id, request_id, response_id, responded_by_id: @jordan.id,
          capability_stable_id: @collaboration.stable_id, level_ordinal: 3, valence: "demonstrated",
          source: "peer", evidence_type: "peer_feedback", content: "Answered.", author_id: @jordan.id)
        create(:evidence_placement_suggestion, tenant: @tenant, evidence_id: response_id, person_id: @alex.id,
          framework_id: @framework_id, capability_stable_id: @ownership.stable_id)
      end

      sign_in @morgan_user
      get evidence_hub_path
      assert_select "##{Views::Evidence::PlacementSuggestions.dom_id_for(response_id)}", count: 1

      ActsAsTenant.with_tenant(@tenant) do
        PersonDevelopment::CommandHandler.new.withdraw_evidence(@alex.id, @framework_id, response_id, withdrawn_by_id: @jordan.id)
      end
      get evidence_hub_path
      assert_select "##{Views::Evidence::PlacementSuggestions.dom_id_for(response_id)}", count: 0
    end
  end

  context "accepting" do
    should "place the item, attribute the decision and answer with the block and a status line" do
      sign_in @morgan_user
      stream_post accept_evidence_placement_suggestion_path(@ownership_suggestion)

      assert_response :success
      assert_equal "text/vnd.turbo-stream.html", response.media_type
      assert_includes response.body, %(target="#{Views::Evidence::PlacementSuggestions.dom_id_for(@item.id)}")
      assert_includes response.body, "Placed on Ownership · E3 as Demonstrates."
      assert_not_includes response.body, %(data-suggestion-id="#{@ownership_suggestion.id}")
      assert_equal [ [ @ownership.stable_id, 3 ] ], links
      ActsAsTenant.with_tenant(@tenant) { assert_equal "accepted", @ownership_suggestion.reload.status }
    end

    should "refuse someone outside the item" do
      sign_in @stranger_user
      stream_post accept_evidence_placement_suggestion_path(@ownership_suggestion)

      assert_redirected_to root_path
      assert_empty links
    end

    should "answer a suggestion decided elsewhere with a 422 and the reason" do
      ActsAsTenant.with_tenant(@tenant) { @ownership_suggestion.decide!(status: "dismissed", by: @alex) }
      sign_in @alex_user
      stream_post accept_evidence_placement_suggestion_path(@ownership_suggestion)

      assert_response :unprocessable_content
      assert_includes response.body, "already dismissed"
    end
  end

  context "dismissing" do
    should "keep the reason and drop the row" do
      sign_in @alex_user
      stream_post dismiss_evidence_placement_suggestion_path(@collaboration_suggestion), params: { reason: "Not about teamwork" }

      assert_response :success
      assert_includes response.body, "Dismissed the suggestion to place it on Collaboration · E4."
      ActsAsTenant.with_tenant(@tenant) do
        assert_equal [ "dismissed", "Not about teamwork" ], @collaboration_suggestion.reload.slice(:status, :dismiss_reason).values
      end
    end
  end

  context "suggesting again" do
    should "enqueue a fresh run" do
      sign_in @alex_user
      Evidence::SuggestionModel.stub(:configured?, true) do
        assert_enqueued_with(job: Evidence::SuggestPlacementsJob, args: [ @item.id ]) do
          stream_post evidence_item_placement_suggestions_path(@item)
        end
      end
      assert_response :success
    end

    should "ask once a minute however often the button is pressed" do
      sign_in @alex_user
      Rails.stub(:cache, ActiveSupport::Cache::MemoryStore.new) do
        Evidence::SuggestionModel.stub(:configured?, true) do
          assert_enqueued_jobs(1, only: Evidence::SuggestPlacementsJob) do
            3.times { stream_post evidence_item_placement_suggestions_path(@item) }
          end
        end
      end
      assert_response :success
    end

    should "ask again for self feedback, for the person who wrote it" do
      item = record_self_feedback
      sign_in @alex_user
      Evidence::SuggestionModel.stub(:configured?, true) do
        assert_enqueued_with(job: Evidence::SuggestPlacementsJob, args: [ item.id ]) do
          stream_post evidence_item_placement_suggestions_path(item)
        end
      end
      assert_response :success
    end

    should "refuse withdrawn feedback" do
      ActsAsTenant.with_tenant(@tenant) do
        PersonDevelopment::CommandHandler.new.withdraw_evidence(@alex.id, @framework_id, @item.id, withdrawn_by_id: @jordan.id)
      end
      sign_in @alex_user
      Evidence::SuggestionModel.stub(:configured?, true) do
        assert_no_enqueued_jobs(only: Evidence::SuggestPlacementsJob) { stream_post evidence_item_placement_suggestions_path(@item) }
      end
      assert_response :unprocessable_content
    end

    should "say so when suggestions are off, and enqueue nothing" do
      switch_suggestions(@tenant, false)
      sign_in @alex_user
      assert_no_enqueued_jobs(only: Evidence::SuggestPlacementsJob) do
        stream_post evidence_item_placement_suggestions_path(@item)
      end
      assert_response :unprocessable_content
      assert_includes response.body, "switched off"
    end
  end

  context "adjusting in the evidence modal" do
    should "stage every pending suggestion as a row, valence preselected" do
      sign_in @morgan_user
      get evidence_modal_path(mode: "edit", evidence_id: @item.id, suggestions: "pending", return_to: "hub")

      assert_response :success
      assert_select "input[name='evidence[suggestion_ids][]'][value='#{@ownership_suggestion.id}']"
      assert_select "input[name='evidence[staged_suggestion_ids][]']", count: 2
      assert_select "select[name='evidence[link_valences][#{@collaboration.stable_id}|4]'] option[selected][value='growth_area']"
      assert_select "[data-testid='suggested-row']", count: 2
    end

    should "accept the rows kept as edited, with attribution, and dismiss the row removed" do
      sign_in @morgan_user
      patch evidence_item_path(@item), params: { evidence: {
        evidence_id: @item.id, assignment_id: @assignment.id,
        desired_links: [ "#{@ownership.stable_id}|3" ],
        link_valences: { "#{@ownership.stable_id}|3" => "strongly_demonstrated" },
        suggestion_ids: [ @ownership_suggestion.id ],
        staged_suggestion_ids: [ @ownership_suggestion.id, @collaboration_suggestion.id ]
      } }

      assert_redirected_to evidence_hub_path
      assert_equal [ [ @ownership.stable_id, 3 ] ], links
      ActsAsTenant.with_tenant(@tenant) do
        assert_equal "edited", @ownership_suggestion.reload.status
        assert_equal [ "dismissed", "Removed while adjusting" ], @collaboration_suggestion.reload.slice(:status, :dismiss_reason).values
      end
      event = Rails.configuration.event_store.read
        .stream(EventStreamNaming.person_development_stream(@alex.id, @framework_id, tenant: @tenant))
        .of_type([ PersonDevelopment::Events::EvidenceLinkAdded ]).backward.first
      assert_equal [ @ownership_suggestion.id, "strongly_demonstrated" ], [ event.data[:via_suggestion_id], event.data[:valence] ]
    end

    should "settle a kept suggestion on a cell someone linked meanwhile" do
      ActsAsTenant.with_tenant(@tenant) do
        PersonDevelopment::CommandHandler.new.add_evidence_link(@alex.id, @framework_id, @item.id,
          capability_stable_id: @ownership.stable_id, level_ordinal: 3, linked_by_id: @alex.id, valence: "growth_area")
      end
      sign_in @morgan_user
      save_adjusted

      ActsAsTenant.with_tenant(@tenant) do
        assert_equal "edited", @ownership_suggestion.reload.status
        assert_equal "demonstrated", EvidenceLink.active.find_by(evidence_id: @item.id).valence
      end
    end

    should "refuse the whole save, writing nothing, when a staged cell left the role" do
      ActsAsTenant.with_tenant(@tenant) do
        FrameworkState::CapabilityRoleBinding.where(capability_id: @ownership.capability_id).delete_all
      end
      sign_in @morgan_user
      save_adjusted(picked: [ "#{@collaboration.stable_id}|3" ])

      assert_redirected_to evidence_hub_path
      assert_match(/no longer on this person's role/, flash[:alert])
      assert_empty links
      ActsAsTenant.with_tenant(@tenant) { assert @ownership_suggestion.reload.pending? }
    end
  end
end
