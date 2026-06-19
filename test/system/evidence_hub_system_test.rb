# frozen_string_literal: true

require "application_system_test_case"

class EvidenceHubSystemTest < ApplicationSystemTestCase
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
    end
  end

  def make_request!
    ActsAsTenant.with_tenant(@tenant) do
      PersonDevelopment::CommandHandler.new.request_evidence(@report.id, @framework_id, SecureRandom.uuid_v7,
        requested_by_id: @report.id, requestee_person_id: @peer.id,
        capability_stable_id: @cap.stable_id, level_ordinal: 2, message: "Pairing notes?")
    end
  end

  should "let the requestee respond with evidence" do
    make_request!
    sign_in_as(@peer_user)
    visit evidence_hub_path
    assert_text "Rep asked you for evidence"

    select "Peer feedback", from: "evidence_request[evidence_type]"
    fill_in "evidence_request[content]", with: "Strong systems thinking during the incident."
    click_button "Provide evidence"

    assert_text "Evidence provided"
    ActsAsTenant.with_tenant(@tenant) { assert_equal "responded", EvidenceRequest.last.status }
  end

  should "let the requester cancel an outgoing request" do
    make_request!
    sign_in_as(@report_user)
    visit evidence_hub_path
    assert_text "To Peer"

    auto_confirm { click_link "Cancel request" }
    assert_text "Request cancelled"
    ActsAsTenant.with_tenant(@tenant) { assert_equal "cancelled", EvidenceRequest.last.status }
  end
end
