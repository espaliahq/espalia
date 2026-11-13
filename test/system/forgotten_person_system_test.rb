# frozen_string_literal: true

require "application_system_test_case"

# Feedback from a colleague who was later forgotten stays on the assessment,
# credited to a former member.
class ForgottenPersonSystemTest < ApplicationSystemTestCase
  DESKTOP_SIZE = [ 1400, 1400 ].freeze
  MOBILE_SIZE = [ 375, 812 ].freeze

  setup do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    @tenant = create(:tenant)
    @user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      person = create(:person, tenant: @tenant, email: @user.email, name: "Alice")
      create(:tenant_user, tenant: @tenant, user: @user, person: person)
      peer = create(:person, tenant: @tenant, name: "Quinn Leaver")

      fx = build_role_lens_framework(tenant: @tenant)
      @assignment, = enrol_in_role_lens_framework(person, fx, tenant: @tenant)
      PersonDevelopment::CommandHandler.new.record_evidence(person.id, fx.framework_id, SecureRandom.uuid_v7,
        capability_stable_id: fx.shared.stable_id, level_ordinal: 2, source: "peer",
        evidence_type: "peer_feedback", title: "Incident retro", content: "Ran the review calmly.",
        author_id: peer.id, valence: "demonstrated")

      peer.update_columns(name: Person::FORMER_MEMBER, email: nil, forgotten_at: Time.current)
    end

    sign_in_as(@user)
  end

  def open_activity
    visit assessment_path(@assignment)
    wait_for_stimulus "activity-pane"
    toggle_activity_pane
    assert_selector "#assessment-activity-pane turbo-frame#assessment-activity[complete]", visible: :all
  end

  def assert_credited_to_former_member
    within "#assessment-activity-pane" do
      assert_text "Incident retro"
      assert_text Person::FORMER_MEMBER
      assert_no_text "Quinn"
    end
  end

  should "credit a forgotten colleague's feedback to a former member on desktop" do
    open_activity
    assert_credited_to_former_member
  end

  should "credit a forgotten colleague's feedback to a former member on mobile" do
    page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
    open_activity
    assert_credited_to_former_member
  end
end
