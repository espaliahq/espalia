# frozen_string_literal: true

require "application_system_test_case"

# A manager of managers sees their own team's feedback to place and
# conversations first, and switches to their whole org with plain links that
# keep the view in the URL.
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
      @role = role = create(:framework_role, role_family_id: rf.role_family_id, name: "SWE", code: "E", track: "ic")
      @level = level = create(:framework_level, role_id: role.role_id, ordinal: 2, title: "Mid", code: "E2")
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

  # The switch's labels as each viewport shows them.
  LABELS = {
    desktop: { mine: "My feedback", team: "My team", org: "My whole org" },
    phone: { mine: "Mine", team: "Team", org: "Whole org" }
  }.freeze

  def switch_between_team_and_org(labels: LABELS[:desktop])
    visit evidence_hub_path
    assert_text "Needs you"
    assert_selector "#needs-you [data-testid='needs-you-place']", text: "Place Jordan's feedback about Alex"
    assert_no_selector "#needs-you [data-testid='needs-you-place']", text: "about Sky"
    assert_selector "nav[aria-label='Whose feedback to show'] a[aria-current='page']", exact_text: "#{labels[:team]} · 1"
    assert_selector "[data-testid='conversation-row'][data-person-id='#{@lead.id}']"
    assert_no_selector "[data-testid='conversation-row'][data-person-id='#{@engineer.id}']"

    click_link_with_js_fallback("#{labels[:org]} · 2", expect_text: "Place Jordan's feedback about Sky")
    assert_selector "#needs-you [data-testid='needs-you-place']", count: 2
    assert_selector "nav[aria-label='Whose feedback to show'] a[aria-current='page']", exact_text: "#{labels[:org]} · 2"
    assert_current_path evidence_hub_path(place: "org")
    assert_selector "[data-testid='conversation-row'][data-person-id='#{@engineer.id}']"

    click_link_with_js_fallback("#{labels[:team]} · 1",
      expect_selector: "nav[aria-label='Whose feedback to show'] a[aria-current='page'][href='#{evidence_hub_path(anchor: "needs-you")}']")
    assert_no_text "Place Jordan's feedback about Sky"
    assert_current_path evidence_hub_path
    assert_no_selector "[data-testid='conversation-row'][data-person-id='#{@engineer.id}']"
  end

  def switch_to_my_feedback(labels: LABELS[:desktop])
    ActsAsTenant.with_tenant(@tenant) do
      PersonDevelopment::CommandHandler.new.tap do |handler|
        handler.assign_to_framework(@manager.id, @framework_id, @role.role_id, @level.level_id)
        handler.record_evidence(@manager.id, @framework_id, SecureRandom.uuid_v7, source: "peer",
          evidence_type: "peer_feedback", content: "Kept the planning meeting to the point.", author_id: @peer.id)
      end
    end
    visit evidence_hub_path
    assert_text "Needs you"

    click_link_with_js_fallback("#{labels[:mine]} · 1", expect_text: "About me")
    assert_current_path evidence_hub_path(place: "mine")
    assert_selector "[data-testid='group-report']", text: "About me"
    assert_selector "#needs-you [data-testid='needs-you-place']", count: 1, text: "Place Jordan's feedback about you"
    assert_selector "[data-testid='conversation-row']", count: 1, text: "About you"
  end

  should "switch to my own feedback and About me on desktop" do
    sign_in_as(@manager_user)
    switch_to_my_feedback
    assert_selector "[data-testid='conversation-thread'] h2", text: "About you"
    assert_selector "[data-testid='conversation-thread']", text: "Kept the planning meeting to the point."
  end

  should "switch to my own feedback and About me on a phone" do
    page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
    sign_in_as(@manager_user)
    switch_to_my_feedback(labels: LABELS[:phone])
    assert_no_sideways_overflow("the three-way switch scrolls sideways on a phone")
  end

  should "switch between my team and my whole org on desktop" do
    sign_in_as(@manager_user)
    switch_between_team_and_org
  end

  should "switch between my team and my whole org on a phone" do
    page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
    sign_in_as(@manager_user)
    switch_between_team_and_org(labels: LABELS[:phone])
    assert_no_sideways_overflow("the hub scrolls sideways on a phone")
  end

  should "take a skip-level manager from the assessment's notice to the item in the whole-org view" do
    sign_in_as(@manager_user)
    visit assessment_path(@engineer_assignment)
    assert_selector "[data-testid='unplaced-feedback-notice']", text: "1 piece of feedback about Sky Okafor is waiting"

    click_link_with_js_fallback("Place it →", expect_text: "Place Jordan's feedback about Sky")
    assert_current_path evidence_hub_path(place: "org")
    assert_selector "nav[aria-label='Whose feedback to show'] a[aria-current='page']", exact_text: "My whole org · 2"
  end
end
