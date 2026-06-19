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
      create(:framework_behavioural_expectation, capability_id: @cap.capability_id, level_ordinal: 2, description: "x")

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
    end

    should "show outgoing requests to the requester" do
      make_request!
      sign_in @report_user
      get evidence_hub_path
      assert_response :success
      assert_match "To Peer", response.body
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
  end

  context "POST respond" do
    should "record peer evidence and resolve the request" do
      id = make_request!
      sign_in @peer_user
      post respond_evidence_request_path(id), params: { evidence_request: { evidence_type: "peer_feedback", content: "Great pairing." } }
      assert_redirected_to evidence_hub_path
      ActsAsTenant.with_tenant(@tenant) { assert_equal "responded", EvidenceRequest.find(id).status }
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
