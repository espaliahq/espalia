# frozen_string_literal: true

require "test_helper"
require_relative "../support/slack_fixture"

# The question the Slack draft path exists to answer: does a person who has
# never signed in, handed a draft link, land on the hub with the modal
# prefilled once they sign in? Devise stores the link, the drafts controller
# checks it is theirs, and the hub and modal read the draft.
class SlackDraftDeepLinkTest < ActionDispatch::IntegrationTest
  include SlackFixture

  setup do
    build_slack_fixture
    @draft = ActsAsTenant.with_tenant(@tenant) do
      FeedbackDraft.create!(tenant: @tenant, author_email: "newcomer@example.com", recipient_person_id: @recipient.id,
                            assignment_id: @assignment.id, content: "Ran the incident call calmly.",
                            evidence_type: "observation", external_reference: { system: "slack", url: "https://slack.example/p1" })
    end
  end

  should "survive sign-in: the link is stored, the hub opens the modal, and the form carries the draft" do
    get @draft.path
    assert_redirected_to new_user_session_path

    # Signing in with a password mirrors what Google sign-in provisions for an
    # HRIS Person: a User + membership for that email.
    user = create(:user, password: "password123", email: "newcomer@example.com")
    ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, user: user, person: @newcomer, role: :member) }
    post user_session_path, params: { user: { email: "newcomer@example.com", password: "password123" } }
    assert_redirected_to @draft.path

    follow_redirect!
    assert_redirected_to evidence_hub_path(draft: @draft.token)

    follow_redirect!
    assert_response :success
    assert_select "[data-controller~='evidence-hub'][data-evidence-hub-auto-open-value='true']"
    assert_select "button[data-evidence-hub-target='autoTrigger'][data-evidence-modal-mode-param='new']" \
                  "[data-evidence-modal-assignment-id-param='#{@assignment.id}'][data-evidence-modal-draft-token-param='#{@draft.token}']"

    get evidence_modal_path(mode: "new", assignment_id: @assignment.id, return_to: "hub", draft_token: @draft.token)
    assert_response :success
    assert_select "textarea#evm-content", text: /Ran the incident call calmly\./
    assert_select "select#evm-type option[selected][value='observation']"
    assert_select "input#evm-url[value='https://slack.example/p1']"
    assert_select "input[name='draft_token'][value='#{@draft.token}']"

    post evidence_items_path, params: { return_to: "hub", draft_token: @draft.token, evidence: {
      assignment_id: @assignment.id, evidence_type: "observation", content: "Ran the incident call calmly."
    } }
    assert_redirected_to evidence_hub_path
    assert_not_nil @draft.reload.consumed_at
    ActsAsTenant.with_tenant(@tenant) { assert_equal 1, EvidenceItem.unplaced.for_person(@recipient.id).count }
  end

  should "refuse an account that owns the email but belongs to another workspace" do
    other_tenant = create(:tenant)
    user = create(:user, password: "password123", email: "newcomer@example.com")
    ActsAsTenant.with_tenant(other_tenant) do
      create(:tenant_user, tenant: other_tenant, user: user, person: create(:person, tenant: other_tenant, email: user.email), role: :member)
    end
    post user_session_path, params: { user: { email: "newcomer@example.com", password: "password123" } }
    get @draft.path
    assert_redirected_to evidence_hub_path
    assert_match(/isn't a member of the workspace/, flash[:alert])
  end

  should "refuse another account's draft, and a consumed one" do
    sign_in_user = @giver_user
    post user_session_path, params: { user: { email: sign_in_user.email, password: "password123" } }
    get @draft.path
    assert_redirected_to evidence_hub_path
    assert_match(/another account/, flash[:alert])

    @draft.consume!
    get @draft.path
    assert_match(/expired or was already used/, flash[:alert])
  end
end
