# frozen_string_literal: true

require "test_helper"

# The hub's proactive-feedback surfaces: the "Give feedback" entry (and its
# auto-open from ?give=1), and the "Feedback to place" lists for the
# recipient and the manager side — never for a peer.
class EvidenceHubControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @tenant = create(:tenant)
    @assessee_user = create(:user, password: "password123")
    @manager_user = create(:user, password: "password123")
    @peer_user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @manager = create(:person, tenant: @tenant, email: @manager_user.email, name: "Morgan")
      @assessee = create(:person, tenant: @tenant, email: @assessee_user.email, name: "Alex", manager: @manager)
      @peer = create(:person, tenant: @tenant, email: @peer_user.email, name: "Jordan")
      create(:tenant_user, tenant: @tenant, user: @assessee_user, person: @assessee, role: :member)
      create(:tenant_user, tenant: @tenant, user: @manager_user, person: @manager, role: :member)
      create(:tenant_user, tenant: @tenant, user: @peer_user, person: @peer, role: :member)

      @framework_id = SecureRandom.uuid_v7
      create(:framework_state, framework_id: @framework_id, name: "Eng")
      rf = create(:framework_role_family, framework_id: @framework_id, name: "Eng")
      role = create(:framework_role, role_family_id: rf.role_family_id, name: "SWE", code: "E", track: "ic")
      level = create(:framework_level, role_id: role.role_id, ordinal: 2, title: "Mid", code: "E2")
      handler = PersonDevelopment::CommandHandler.new
      handler.assign_to_framework(@assessee.id, @framework_id, role.role_id, level.level_id)
      @unplaced_id = SecureRandom.uuid_v7
      handler.record_evidence(@assessee.id, @framework_id, @unplaced_id,
        source: "peer", evidence_type: "peer_feedback", content: "Ran the incident call calmly.", author_id: @peer.id)
    end
  end

  context "giving feedback" do
    should "offer the Give feedback entry and leave the modal closed by default" do
      sign_in @peer_user
      get evidence_hub_path
      assert_response :success
      assert_select "button[data-evidence-modal-mode-param='give']", text: "Give feedback"
      assert_select "[data-controller~='evidence-hub'][data-evidence-hub-auto-open-value='true']", count: 0
    end

    should "open the give step on arrival when asked to" do
      sign_in @peer_user
      get evidence_hub_path(give: 1)
      assert_select "[data-controller~='evidence-hub'][data-evidence-hub-auto-open-value='true']"
      assert_select "button[data-evidence-hub-target='autoTrigger'][data-evidence-modal-mode-param='give']"
    end
  end

  context "feedback to place" do
    should "list an unplaced item about the viewer, with a Place action on its anchored card" do
      sign_in @assessee_user
      get evidence_hub_path
      assert_select "section#feedback-to-place" do
        assert_select "h3", text: /About you/
        assert_select "##{EvidenceItem.dom_id(@unplaced_id)}" do
          assert_select "button[data-evidence-modal-mode-param='edit'][data-evidence-modal-evidence-id-param='#{@unplaced_id}']",
            text: "Place on a capability"
        end
      end
      assert_select "p", text: /From Jordan/
      assert_select "p", text: /on Alex's assessment/, count: 0
    end

    should "list a report's unplaced item for their manager, naming the report" do
      sign_in @manager_user
      get evidence_hub_path
      assert_select "section#feedback-to-place" do
        assert_select "h3", text: /About your reports/
        assert_select "p", text: /on Alex's assessment/
      end
    end

    should "show a peer nothing to place, only what they gave" do
      sign_in @peer_user
      get evidence_hub_path
      assert_select "section#feedback-to-place", count: 0
      assert_select "p", text: "Feedback, not yet placed on a capability"
    end

    should "drop a placed item from the list" do
      ActsAsTenant.with_tenant(@tenant) do
        cat = create(:framework_capability_category, framework_id: @framework_id, name: "Thinking", ordinal: 1)
        cap = create(:framework_capability, category_id: cat.category_id, name: "Critical Thinking")
        PersonDevelopment::CommandHandler.new.add_evidence_link(@assessee.id, @framework_id, @unplaced_id,
          capability_stable_id: cap.stable_id, level_ordinal: 2, linked_by_id: @assessee.id, valence: "demonstrated")
      end
      sign_in @assessee_user
      get evidence_hub_path
      assert_select "section#feedback-to-place", count: 0
    end
  end
end
