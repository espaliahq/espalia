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

    should "list a report's item for an active rating delegate on that framework" do
      delegate_user = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) do
        delegate = create(:person, tenant: @tenant, email: delegate_user.email, name: "Devon")
        create(:tenant_user, tenant: @tenant, user: delegate_user, person: delegate, role: :member)
        PersonDevelopment::CommandHandler.new.delegate_manager_rating(@assessee.id, @framework_id, delegate.id,
          granted_by_id: @manager.id)
      end
      sign_in delegate_user
      get evidence_hub_path
      assert_select "section#feedback-to-place h3", text: /About your reports/
    end

    should "list a manager's own unplaced item about a report once, under what they gave" do
      own = SecureRandom.uuid_v7
      ActsAsTenant.with_tenant(@tenant) do
        PersonDevelopment::CommandHandler.new.record_evidence(@assessee.id, @framework_id, own,
          source: "manager", evidence_type: "observation", content: "Calm under pressure", author_id: @manager.id)
      end
      sign_in @manager_user
      get evidence_hub_path
      assert_select "##{EvidenceItem.dom_id(own)}", count: 1
      assert_select "section#feedback-to-place ##{EvidenceItem.dom_id(own)}", count: 0
      assert_select "p", text: "Feedback, not yet placed on a capability"
    end

    should "show no team/org toggle to a manager with no one beyond their team" do
      sign_in @manager_user
      get evidence_hub_path
      assert_select "nav[aria-label='Whose feedback to place']", count: 0
    end

    context "with a skip-level report" do
      setup do
        ActsAsTenant.with_tenant(@tenant) do
          @deep = create(:person, tenant: @tenant, name: "Sky", manager: @assessee)
          handler = PersonDevelopment::CommandHandler.new
          assignment = PersonFrameworkAssignment.find_by!(person_id: @assessee.id)
          handler.assign_to_framework(@deep.id, @framework_id, assignment.role_id, assignment.level_id)
          @deep_item = SecureRandom.uuid_v7
          handler.record_evidence(@deep.id, @framework_id, @deep_item,
            source: "peer", evidence_type: "peer_feedback", content: "Wrote the runbook.", author_id: @peer.id)
        end
        sign_in @manager_user
      end

      should "list only the team by default, with both counts on the toggle" do
        get evidence_hub_path
        assert_select "##{EvidenceItem.dom_id(@unplaced_id)}"
        assert_select "##{EvidenceItem.dom_id(@deep_item)}", count: 0
        assert_select "nav[aria-label='Whose feedback to place']" do
          assert_select "a[href='#{evidence_hub_path(anchor: "feedback-to-place")}'][aria-current='page']", text: "My team · 1"
          assert_select "a[href='#{evidence_hub_path(place: "org", anchor: "feedback-to-place")}']:not([aria-current])",
            text: "My whole org · 2"
        end
      end

      should "list the whole org for ?place=org" do
        get evidence_hub_path(place: "org")
        assert_select "##{EvidenceItem.dom_id(@unplaced_id)}"
        assert_select "##{EvidenceItem.dom_id(@deep_item)}"
        assert_select "nav a[aria-current='page']", text: "My whole org · 2"
      end

      should "treat an unknown view as the team" do
        get evidence_hub_path(place: "tenant")
        assert_select "##{EvidenceItem.dom_id(@deep_item)}", count: 0
        assert_select "nav a[aria-current='page']", text: "My team · 1"
      end

      should "keep the section and its toggle when only the org has feedback to place" do
        ActsAsTenant.with_tenant(@tenant) do
          cat = create(:framework_capability_category, framework_id: @framework_id, name: "Thinking", ordinal: 1)
          cap = create(:framework_capability, category_id: cat.category_id, name: "Critical Thinking")
          PersonDevelopment::CommandHandler.new.add_evidence_link(@assessee.id, @framework_id, @unplaced_id,
            capability_stable_id: cap.stable_id, level_ordinal: 2, linked_by_id: @manager.id, valence: "demonstrated")
        end
        get evidence_hub_path
        assert_select "section#feedback-to-place" do
          assert_select "p", text: "Nothing about your team is waiting to be placed."
          assert_select "nav a", text: "My whole org · 1"
        end
      end

      should "scope suggestions on placed items the same way" do
        placed = SecureRandom.uuid_v7
        ActsAsTenant.with_tenant(@tenant) do
          cat = create(:framework_capability_category, framework_id: @framework_id, name: "Thinking", ordinal: 1)
          cap = create(:framework_capability, category_id: cat.category_id, name: "Critical Thinking")
          other = create(:framework_capability, category_id: cat.category_id, name: "Systems Design")
          PersonDevelopment::CommandHandler.new.record_evidence(@deep.id, @framework_id, placed,
            source: "peer", evidence_type: "peer_feedback", content: "Mapped the dependencies.", author_id: @peer.id,
            capability_stable_id: cap.stable_id, level_ordinal: 2, valence: "demonstrated")
          create(:evidence_placement_suggestion, tenant: @tenant, item: EvidenceItem.find(placed),
            capability_stable_id: other.stable_id, level_ordinal: 2)
        end

        get evidence_hub_path
        assert_select "##{EvidenceItem.dom_id(placed)}", count: 0
        get evidence_hub_path(place: "org")
        assert_select "section#suggested-placements ##{EvidenceItem.dom_id(placed)}"
      end
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
