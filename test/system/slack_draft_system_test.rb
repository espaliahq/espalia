# frozen_string_literal: true

require "application_system_test_case"
require_relative "../support/slack_fixture"

# The draft link in a real browser: arriving signed out, signing in, and
# finding the modal already open and filled from what was written in Slack.
class SlackDraftSystemTest < ApplicationSystemTestCase
  include SlackFixture

  setup do
    build_slack_fixture
    @author_user = create(:user, password: "password123", email: "newcomer@example.com")
    ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, user: @author_user, person: @newcomer, role: :member) }
    @draft = ActsAsTenant.with_tenant(@tenant) do
      FeedbackDraft.create!(tenant: @tenant, author_email: "newcomer@example.com", recipient_person_id: @recipient.id,
                            assignment_id: @assignment.id, content: "Ran the incident call calmly.", evidence_type: "peer_feedback")
    end
  end

  should "open the prefilled form for Alex after signing in through the link" do
    visit @draft.path
    assert_current_path new_user_session_path
    fill_in "Email", with: "newcomer@example.com"
    fill_in "Password", with: "password123"
    click_button_with_js_fallback("Log in", expect_text: "For Alex Chen")
    assert_field "What happened?", with: "Ran the incident call calmly."
    assert_text "Not sure which capability this speaks to?"
    click_selector_with_js_fallback("form[action='/evidence_items'] button[type='submit']",
                                    expect_text: "Feedback recorded — not yet placed on a capability.")
    assert_not_nil @draft.reload.consumed_at
  end
end
