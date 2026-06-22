# frozen_string_literal: true

require "test_helper"

class EvidenceRequestsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @tenant = create(:tenant)
    @report_user = create(:user, password: "password123")
    @peer_user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @report = create(:person, tenant: @tenant, email: @report_user.email, name: "Rep")
      @peer = create(:person, tenant: @tenant, email: @peer_user.email, name: "Peer")
      create(:tenant_user, tenant: @tenant, user: @report_user, person: @report, role: :member)
      create(:tenant_user, tenant: @tenant, user: @peer_user, person: @peer, role: :member)

      @framework_id = SecureRandom.uuid_v7
      create(:framework_state, framework_id: @framework_id, name: "Eng")
      rf = create(:framework_role_family, framework_id: @framework_id, name: "Eng")
      role = create(:framework_role, role_family_id: rf.role_family_id, name: "SWE", code: "E", track: "ic")
      level = create(:framework_level, role_id: role.role_id, ordinal: 2, title: "Mid", code: "E2")
      cat = create(:framework_capability_category, framework_id: @framework_id, name: "Thinking", ordinal: 1)
      @cap = create(:framework_capability, category_id: cat.category_id, name: "Critical Thinking")
      create(:framework_capability_role_binding, capability_id: @cap.capability_id, role_id: role.role_id, weight: 1.0)
      expectation = create(:framework_behavioural_expectation, capability_id: @cap.capability_id, level_ordinal: 2, description: "Synthesises competing trade-offs")
      create(:framework_role_illustration, expectation_id: expectation.expectation_id, role_id: role.role_id, ordinal: 1, description: "Wrote the migration RFC")

      PersonDevelopment::CommandHandler.new.assign_to_framework(@report.id, @framework_id, role.role_id, level.level_id)
      @assignment = PersonFrameworkAssignment.for_person(@report.id).first
    end
  end

  def make_request!
    id = SecureRandom.uuid_v7
    ActsAsTenant.with_tenant(@tenant) do
      PersonDevelopment::CommandHandler.new.request_evidence(@report.id, @framework_id, id,
        requested_by_id: @report.id, requestee_person_id: @peer.id,
        capability_stable_id: @cap.stable_id, level_ordinal: 2, message: "Pairing notes?")
    end
    id
  end

  context "GET /evidence" do
    should "show incoming requests to the requestee" do
      make_request!
      sign_in @peer_user
      get evidence_hub_path
      assert_response :success
      assert_match "Rep asked you for evidence", response.body
      assert_match "Critical Thinking", response.body
      # Compact context — role + level code; the full expectation/examples live
      # in the modal you open to respond, not on the card.
      assert_match "SWE · E2", response.body
      assert_no_match "Synthesises competing trade-offs", response.body
    end

    should "show outgoing requests to the requester" do
      make_request!
      sign_in @report_user
      get evidence_hub_path
      assert_response :success
      assert_match "To Peer", response.body
    end

    should "name the assessee with 'regarding' when a manager asks on a report's behalf" do
      manager_user = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) do
        manager = create(:person, tenant: @tenant, email: manager_user.email, name: "Boss")
        create(:tenant_user, tenant: @tenant, user: manager_user, person: manager, role: :member)
        @report.update!(manager: manager)
        PersonDevelopment::CommandHandler.new.request_evidence(@report.id, @framework_id, SecureRandom.uuid_v7,
          requested_by_id: manager.id, requestee_person_id: @peer.id,
          capability_stable_id: @cap.stable_id, level_ordinal: 2, message: "Saw them pair?")
      end
      # Incoming (the peer) names who it's regarding…
      sign_in @peer_user
      get evidence_hub_path
      assert_match "Boss asked you for evidence, regarding Rep", response.body
      # …and the requester's outgoing card does too.
      sign_in manager_user
      get evidence_hub_path
      assert_match "To Peer, regarding Rep", response.body
    end

    should "omit 'regarding' when the requester asks about their own assessment" do
      make_request! # requested_by == assessee (@report)
      sign_in @peer_user
      get evidence_hub_path
      assert_no_match(/regarding/, response.body)
    end

    should "embed the provided evidence on a responded outgoing request" do
      id = make_request!
      ActsAsTenant.with_tenant(@tenant) do
        evidence_id = SecureRandom.uuid_v7
        handler = PersonDevelopment::CommandHandler.new
        handler.record_evidence(@report.id, @framework_id, evidence_id,
          capability_stable_id: @cap.stable_id, level_ordinal: 2, source: "peer",
          evidence_type: "peer_feedback", content: "Solid pairing partner.", author_id: @peer.id)
        handler.respond_to_evidence_request(@report.id, @framework_id, id, evidence_id: evidence_id, responded_by_id: @peer.id)
      end
      sign_in @report_user
      get evidence_hub_path
      assert_match "Response from Peer", response.body
      assert_match "Solid pairing partner.", response.body
      assert_match "Applies to: Critical Thinking E2", response.body
      assert_select "button[data-evidence-modal-mode-param='edit']", text: "Edit links"
    end
  end

  context "POST create" do
    should "let the assessee request evidence" do
      sign_in @report_user
      assert_difference -> { ActsAsTenant.with_tenant(@tenant) { EvidenceRequest.count } }, 1 do
        post evidence_requests_path, params: { evidence_request: {
          assignment_id: @assignment.id, requestee_person_id: @peer.id,
          capability_stable_id: @cap.stable_id, level_ordinal: 2, message: "Help"
        } }
      end
      assert_response :redirect
    end

    should "send one request per recipient with a shared reason (multi-select)" do
      peer2 = ActsAsTenant.with_tenant(@tenant) { create(:person, tenant: @tenant, name: "Peer Two") }
      sign_in @report_user
      assert_difference -> { ActsAsTenant.with_tenant(@tenant) { EvidenceRequest.pending.count } }, 2 do
        post evidence_requests_path, params: { evidence_request: {
          assignment_id: @assignment.id, capability_stable_id: @cap.stable_id, level_ordinal: 2,
          message: "Saw you pair on the incident", requestee_ids: [ @peer.id, peer2.id ]
        } }
      end
      follow_redirect!
      assert_match(/sent to 2 people/i, flash[:notice] || response.body)
    end

    should "skip an invalid recipient and summarise" do
      sign_in @report_user
      # @report is the assessee — asking them is rejected and counted as skipped.
      assert_difference -> { ActsAsTenant.with_tenant(@tenant) { EvidenceRequest.pending.count } }, 1 do
        post evidence_requests_path, params: { evidence_request: {
          assignment_id: @assignment.id, capability_stable_id: @cap.stable_id, level_ordinal: 2,
          message: "x", requestee_ids: [ @peer.id, @report.id ]
        } }
      end
      assert_match(/skipped 1/i, flash[:notice].to_s)
    end

    should "deny an unrelated user" do
      stranger = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) do
        sp = create(:person, tenant: @tenant, email: stranger.email, name: "Stranger")
        create(:tenant_user, tenant: @tenant, user: stranger, person: sp, role: :member)
      end
      sign_in stranger
      post evidence_requests_path, params: { evidence_request: {
        assignment_id: @assignment.id, requestee_person_id: @peer.id,
        capability_stable_id: @cap.stable_id, level_ordinal: 2
      } }
      assert_redirected_to root_path
    end
  end

  context "GET evidence_request_modal" do
    should "render the request form with the cell context for an authorised requester" do
      sign_in @report_user
      get evidence_request_modal_path(assignment_id: @assignment.id,
        capability_stable_id: @cap.stable_id, level_ordinal: 2)
      assert_response :success
      assert_match "Request evidence", response.body
      assert_match "Critical Thinking", response.body
    end

    should "deny an unrelated user" do
      stranger = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) do
        sp = create(:person, tenant: @tenant, email: stranger.email, name: "Stranger")
        create(:tenant_user, tenant: @tenant, user: stranger, person: sp, role: :member)
      end
      sign_in stranger
      get evidence_request_modal_path(assignment_id: @assignment.id,
        capability_stable_id: @cap.stable_id, level_ordinal: 2)
      assert_redirected_to root_path
    end
  end

  context "GET evidence_request_candidates" do
    should "return typeahead matches by name" do
      sign_in @report_user
      get evidence_request_candidates_path(assignment_id: @assignment.id,
        capability_stable_id: @cap.stable_id, level_ordinal: 2, q: "Peer")
      assert_response :success
      assert_match "Peer", response.body
    end
  end

  context "POST respond" do
    should "record peer evidence and resolve the request" do
      id = make_request!
      sign_in @peer_user
      cell = "#{@cap.stable_id}|2"
      post respond_evidence_request_path(id), params: { return_to: "hub", evidence: {
        request_id: id, primary_cell: cell, desired_links: [ cell ],
        evidence_type: "peer_feedback", content: "Great pairing."
      } }
      assert_redirected_to evidence_hub_path
      ActsAsTenant.with_tenant(@tenant) { assert_equal "responded", EvidenceRequest.find(id).status }
    end

    should "capture the full evidence fields incl. title and external link" do
      id = make_request!
      sign_in @peer_user
      cell = "#{@cap.stable_id}|2"
      post respond_evidence_request_path(id), params: { return_to: "hub", evidence: {
        request_id: id, primary_cell: cell, desired_links: [ cell ],
        evidence_type: "code_review", title: "Pairing on the parser",
        content: "Drove the recursive-descent refactor together.",
        external_reference: { system: "github", url: "https://github.com/example/repo/pull/9" }
      } }
      assert_redirected_to evidence_hub_path

      ActsAsTenant.with_tenant(@tenant) do
        item = EvidenceItem.find(EvidenceRequest.find(id).evidence_id)
        assert_equal "code_review", item.evidence_type
        assert_equal "Pairing on the parser", item.title
        assert_equal "https://github.com/example/repo/pull/9", item.external_reference.url
      end
    end

    should "render a Provide evidence modal trigger on the incoming card" do
      make_request!
      sign_in @peer_user
      get evidence_hub_path
      assert_select "button[data-evidence-modal-mode-param='respond']", text: "Provide evidence"
    end

    should "deny a non-requestee" do
      id = make_request!
      sign_in @report_user
      post respond_evidence_request_path(id), params: { evidence_request: { evidence_type: "peer_feedback", content: "x" } }
      assert_redirected_to root_path
      ActsAsTenant.with_tenant(@tenant) { assert_equal "pending", EvidenceRequest.find(id).status }
    end
  end

  context "POST decline / DELETE cancel" do
    should "let the requestee decline" do
      id = make_request!
      sign_in @peer_user
      post decline_evidence_request_path(id), params: { evidence_request: { reason: "No overlap" } }
      assert_redirected_to evidence_hub_path
      ActsAsTenant.with_tenant(@tenant) { assert_equal "declined", EvidenceRequest.find(id).status }
    end

    should "let the requester cancel" do
      id = make_request!
      sign_in @report_user
      delete evidence_request_path(id)
      assert_redirected_to evidence_hub_path
      ActsAsTenant.with_tenant(@tenant) { assert_equal "cancelled", EvidenceRequest.find(id).status }
    end
  end
end
