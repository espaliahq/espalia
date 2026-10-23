# frozen_string_literal: true

require "application_system_test_case"

# A manager of managers sees their own team's feedback to place first, and
# switches to their whole org with plain links that keep the view in the URL.
class FeedbackToPlaceScopeSystemTest < ApplicationSystemTestCase
  DESKTOP_SIZE = [ 1400, 1400 ].freeze
  MOBILE_SIZE = [ 375, 812 ].freeze

  setup do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    @tenant = create(:tenant)
    @manager_user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @manager = create(:person, tenant: @tenant, email: @manager_user.email, name: "Morgan Reyes")
      @lead = create(:person, tenant: @tenant, name: "Alex Rivera", manager: @manager)
      @engineer = create(:person, tenant: @tenant, name: "Sky Okafor", manager: @lead)
      @peer = create(:person, tenant: @tenant, name: "Jordan Lee")
      create(:tenant_user, tenant: @tenant, user: @manager_user, person: @manager, role: :member)

      @framework_id = SecureRandom.uuid_v7
      create(:framework_state, framework_id: @framework_id, name: "Eng")
      rf = create(:framework_role_family, framework_id: @framework_id, name: "Eng")
      role = create(:framework_role, role_family_id: rf.role_family_id, name: "SWE", code: "E", track: "ic")
      level = create(:framework_level, role_id: role.role_id, ordinal: 2, title: "Mid", code: "E2")
      cat = create(:framework_capability_category, framework_id: @framework_id, name: "Thinking", ordinal: 1)
      cap = create(:framework_capability, category_id: cat.category_id, name: "Critical Thinking")
      create(:framework_capability_role_binding, capability_id: cap.capability_id, role_id: role.role_id, weight: 1.0)
      create(:framework_behavioural_expectation, capability_id: cap.capability_id, level_ordinal: 2,
        description: "Weighs options and explains reasoning")
      handler = PersonDevelopment::CommandHandler.new
      [ @lead, @engineer ].each { |person| handler.assign_to_framework(person.id, @framework_id, role.role_id, level.level_id) }
      @engineer_assignment = PersonFrameworkAssignment.find_by(person_id: @engineer.id)

      @lead_item = SecureRandom.uuid_v7
      handler.record_evidence(@lead.id, @framework_id, @lead_item, source: "peer", evidence_type: "peer_feedback",
        content: "Chaired the planning session well.", author_id: @peer.id)
      @engineer_item = SecureRandom.uuid_v7
      handler.record_evidence(@engineer.id, @framework_id, @engineer_item, source: "peer", evidence_type: "peer_feedback",
        content: "Wrote the on-call runbook.", author_id: @peer.id)
    end
  end

  def switch_between_team_and_org
    visit evidence_hub_path
    assert_text "Feedback to place"
    assert_selector "##{EvidenceItem.dom_id(@lead_item)}", text: "Chaired the planning session well."
    assert_no_selector "##{EvidenceItem.dom_id(@engineer_item)}"
    assert_selector "nav[aria-label='Whose feedback to place'] a[aria-current='page']", text: "My team · 1"

    click_link_with_js_fallback("My whole org · 2", expect_text: "Wrote the on-call runbook.")
    assert_selector "##{EvidenceItem.dom_id(@lead_item)}"
    assert_selector "nav[aria-label='Whose feedback to place'] a[aria-current='page']", text: "My whole org · 2"
    assert_current_path evidence_hub_path(place: "org")

    click_link_with_js_fallback("My team · 1",
      expect_selector: "nav[aria-label='Whose feedback to place'] a[aria-current='page'][href='#{evidence_hub_path(anchor: "feedback-to-place")}']")
    assert_no_text "Wrote the on-call runbook."
    assert_current_path evidence_hub_path
  end

  should "switch between my team and my whole org on desktop" do
    sign_in_as(@manager_user)
    switch_between_team_and_org
  end

  should "switch between my team and my whole org on a phone" do
    page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
    sign_in_as(@manager_user)
    switch_between_team_and_org
    assert_no_sideways_overflow("the hub scrolls sideways on a phone")
  end

  should "take a skip-level manager from the assessment's notice to the item in the whole-org view" do
    sign_in_as(@manager_user)
    visit assessment_path(@engineer_assignment)
    assert_selector "[data-testid='unplaced-feedback-notice']", text: "1 piece of feedback about Sky Okafor is waiting"

    click_link_with_js_fallback("Place it →", expect_text: "Wrote the on-call runbook.")
    assert_current_path evidence_hub_path(place: "org")
    assert_selector "nav[aria-label='Whose feedback to place'] a[aria-current='page']", text: "My whole org · 2"
  end
end
