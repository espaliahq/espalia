# frozen_string_literal: true

require "application_system_test_case"

# Volunteering feedback end to end: a peer gives it from the hub without ever
# opening the assessment, saving it unplaced; the recipient finds it under
# "Feedback to place", places it on a capability, and it lands in the cell.
# The assessment itself tells the recipient something is waiting.
class GiveFeedbackSystemTest < ApplicationSystemTestCase
  DESKTOP_SIZE = [ 1400, 1400 ].freeze
  MOBILE_SIZE = [ 375, 812 ].freeze

  setup do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    @tenant = create(:tenant)
    @recipient_user = create(:user, password: "password123")
    @peer_user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @recipient = create(:person, tenant: @tenant, email: @recipient_user.email, name: "Priya Patel")
      @peer = create(:person, tenant: @tenant, email: @peer_user.email, name: "Jordan Lee")
      create(:person, tenant: @tenant, name: "Priyanka Nair", email: "priyanka@example.com")
      create(:tenant_user, tenant: @tenant, user: @recipient_user, person: @recipient, role: :member)
      create(:tenant_user, tenant: @tenant, user: @peer_user, person: @peer, role: :member)

      @framework_id = SecureRandom.uuid_v7
      create(:framework_state, framework_id: @framework_id, name: "Eng")
      rf = create(:framework_role_family, framework_id: @framework_id, name: "Eng")
      role = create(:framework_role, role_family_id: rf.role_family_id, name: "SWE", code: "E", track: "ic")
      level = create(:framework_level, role_id: role.role_id, ordinal: 2, title: "Mid", code: "E2")
      cat = create(:framework_capability_category, framework_id: @framework_id, name: "Thinking", ordinal: 1)
      @cap = create(:framework_capability, category_id: cat.category_id, name: "Critical Thinking")
      create(:framework_capability_role_binding, capability_id: @cap.capability_id, role_id: role.role_id, weight: 1.0)
      create(:framework_behavioural_expectation, capability_id: @cap.capability_id, level_ordinal: 2,
        description: "Weighs options and explains reasoning")
      PersonDevelopment::CommandHandler.new.assign_to_framework(@recipient.id, @framework_id, role.role_id, level.level_id)
      @assignment = PersonFrameworkAssignment.find_by(person_id: @recipient.id, framework_id: @framework_id)
    end
  end

  def give_feedback_from_hub
    visit evidence_hub_path
    assert_text "Feedback / Evidence"
    click_button_with_js_fallback("Give feedback", expect_text: "Who is it for?")

    # Typing is the assertion-critical input (a dropped keystroke changes the
    # query), and only the assessed Priya may appear — Priyanka has no assessment.
    js_fill_in "Who is it for?", with: "Pri"
    assert_selector "turbo-frame#evidence-recipients a[data-recipient-row]", text: "Priya Patel"
    assert_no_selector "turbo-frame#evidence-recipients a[data-recipient-row]", text: "Priyanka Nair"

    # The row is a frame-targeting link in a floating panel; a dropped pointer
    # click leaves the picker up, so dispatch it if the form never arrives.
    click_selector_with_js_fallback("turbo-frame#evidence-recipients a[data-recipient-row]",
                                    expect_text: "Not sure which capability this speaks to?")
    assert_text "For Priya Patel"
    assert_text "visible to Priya Patel, their managers, and workspace admins"
    assert_no_selector "[data-link-row]"

    # Asserted verbatim, so js_fill_in: a long fill_in types only its ends and can drop its first word.
    js_fill_in "What happened?", with: "Ran the incident call calmly and kept everyone informed."
    # The header's "Give feedback" is still a visible button behind the overlay;
    # the submit is the form's.
    click_selector_with_js_fallback("form[action='/evidence_items'] button[type='submit']",
                                    expect_text: "Feedback recorded — not yet placed on a capability.")
  end

  should "let a peer give unplaced feedback from the hub, on desktop" do
    sign_in_as(@peer_user)
    give_feedback_from_hub
    within("[data-testid='conversation-thread']") { assert_text "Not placed yet" }

    item = ActsAsTenant.with_tenant(@tenant) { EvidenceItem.unplaced.for_person(@recipient.id).first }
    assert_not_nil item
    assert_equal @peer.id, item.author_id
    assert_equal "peer", item.source
  end

  should "let a peer give unplaced feedback from the hub, on mobile" do
    page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
    sign_in_as(@peer_user)
    give_feedback_from_hub
    assert_selector "[data-testid='conversation-row']", text: /You: Ran the incident call calmly/, visible: true
  end

  should "tell the recipient on the assessment and let them place it from the hub" do
    ActsAsTenant.with_tenant(@tenant) do
      PersonDevelopment::CommandHandler.new.record_evidence(@recipient.id, @framework_id, SecureRandom.uuid_v7,
        source: "peer", evidence_type: "peer_feedback", content: "Ran the incident call calmly.", author_id: @peer.id)
    end
    sign_in_as(@recipient_user)

    visit assessment_path(@assignment)
    assert_selector "[data-testid='unplaced-feedback-notice']", text: "1 piece of feedback about you is waiting"
    click_link_with_js_fallback("Place it →", expect_text: "Needs you")
    assert_text "Place Jordan's feedback about you"

    click_selector_with_js_fallback("#needs-you button[data-evidence-modal-mode-param='edit']",
                                    expect_text: "Edit feedback / evidence")
    assert_no_selector "[data-link-row]"
    # The picker's selects carry aria-labels, which Capybara's `select` does
    # not match here; address them directly.
    find("select[aria-label='Capability to also link']").select("Critical Thinking")
    find("select[aria-label='Level to also link'] option[value='2']").select_option
    click_selector_with_js_fallback("button[data-action='evidence-modal#addLink']", expect_selector: "[data-link-row]")
    assert_selector "[data-link-row]", count: 1
    find("[data-link-row] select[aria-label='Evidence valence']").select("Demonstrates")
    click_button_with_js_fallback("Save changes", expect_text: "Feedback updated.")
    assert_no_selector "#needs-you [data-testid='needs-you-place']"

    visit assessment_path(@assignment, capability: @cap.stable_id, level_ordinal: 2)
    assert_no_selector "[data-testid='unplaced-feedback-notice']"
    assert_text "Ran the incident call calmly."
  end
end
