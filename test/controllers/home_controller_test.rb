# frozen_string_literal: true

require "test_helper"

class HomeControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    @user = create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) do
      @person = create(:person, tenant: @tenant, email: @user.email, name: "Test User")
      create(:tenant_user, tenant: @tenant, user: @user, person: @person)

      # The viewer is enrolled in an open cycle as an assessee.
      @cycle = create(:assessment_cycle, tenant: @tenant, name: "Q1 2026", status: "open")
      create(:person_framework_assignment,
        tenant: @tenant, person_id: @person.id, framework_id: @cycle.framework_id)
      create(:assessment_cycle_enrollment,
        tenant: @tenant, cycle: @cycle, person_id: @person.id, status: "enrolled")
      create(:assessment_cycle_progress,
        tenant: @tenant, cycle: @cycle, person_id: @person.id, status: "started")
    end
  end

  context "GET / (show)" do
    should "render the dashboard with a lazy frame per visible card" do
      sign_in @user
      get root_path

      assert_response :success
      assert_includes response.body, "Home"
      # Lazy frame placeholder for the assessment-progress card (one open cycle)
      assert_includes response.body, home_card_path(card: "assessment_progress", key: @cycle.cycle_id)
    end

    should "redirect unauthenticated users to sign in" do
      get root_path
      assert_redirected_to new_user_session_path
    end

    should "render the empty state for a user with nothing to act on" do
      bare_user = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) do
        bare = create(:person, tenant: @tenant, email: bare_user.email, name: "Bare")
        create(:tenant_user, tenant: @tenant, user: bare_user, person: bare)
      end

      sign_in bare_user
      get root_path

      assert_response :success
      assert_includes response.body, "Nothing needs your attention right now."
    end
  end

  context "GET /home/cards/:card (card content)" do
    should "render the assessment-progress card frame without layout" do
      sign_in @user
      get home_card_path(card: "assessment_progress", key: @cycle.cycle_id)

      assert_response :success
      assert_not_includes response.body, "<html"
      assert_includes response.body, "Q1 2026"
      assert_includes response.body, "Continue self-assessment"
    end

    should "render the awaiting-you card frame for a manager with a pending report" do
      ActsAsTenant.with_tenant(@tenant) do
        report = create(:person, tenant: @tenant, name: "Report One", manager: @person)
        create(:assessment_cycle_enrollment,
          tenant: @tenant, cycle: @cycle, person_id: report.id, status: "enrolled")
        create(:assessment_cycle_progress,
          tenant: @tenant, cycle: @cycle, person_id: report.id, status: "started")
      end

      sign_in @user
      get home_card_path(card: "awaiting_you", key: "default")

      assert_response :success
      assert_includes response.body, "Awaiting you"
      assert_includes response.body, "Report One"
      assert_includes response.body, "Review team"
    end

    should "render the cycle-progress card frame for a manager with a report" do
      ActsAsTenant.with_tenant(@tenant) do
        report = create(:person, tenant: @tenant, name: "Report One", manager: @person)
        create(:assessment_cycle_enrollment,
          tenant: @tenant, cycle: @cycle, person_id: report.id, status: "enrolled")
        create(:assessment_cycle_progress,
          tenant: @tenant, cycle: @cycle, person_id: report.id, status: "started")
      end

      sign_in @user
      get home_card_path(card: "cycle_progress", key: @cycle.cycle_id)

      assert_response :success
      assert_includes response.body, "Cycle progress"
      assert_includes response.body, "View progress"
    end

    should "deny a cycle-progress instance the manager has no reports in (per-instance guard)" do
      other_cycle = nil
      ActsAsTenant.with_tenant(@tenant) do
        # @person gains the cohort card audience via a report in @cycle...
        report = create(:person, tenant: @tenant, name: "Report One", manager: @person)
        create(:assessment_cycle_enrollment,
          tenant: @tenant, cycle: @cycle, person_id: report.id, status: "enrolled")
        # ...but has no reports in this unrelated open cycle.
        other_cycle = create(:assessment_cycle,
          tenant: @tenant, framework_id: SecureRandom.uuid_v7, status: "open")
      end

      sign_in @user
      get home_card_path(card: "cycle_progress", key: other_cycle.cycle_id)

      assert_response :redirect
    end

    should "404 for an unknown card" do
      sign_in @user
      get home_card_path(card: "does-not-exist", key: "default")

      assert_response :not_found
    end

    should "deny a card the viewer is not an audience for" do
      outsider = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) do
        person = create(:person, tenant: @tenant, email: outsider.email, name: "Outsider")
        create(:tenant_user, tenant: @tenant, user: outsider, person: person)
      end

      sign_in outsider
      get home_card_path(card: "assessment_progress", key: @cycle.cycle_id)

      assert_response :redirect
    end
  end

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end
