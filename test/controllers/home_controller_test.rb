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
      @role = create(:framework_role, tenant: @tenant)
      create(:person_framework_assignment,
        tenant: @tenant, person_id: @person.id, framework_id: @cycle.framework_id, role_id: @role.role_id)
      create(:assessment_cycle_enrollment,
        tenant: @tenant, cycle: @cycle, person_id: @person.id, status: "enrolled", level_ordinal: 3)
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

    should "offer the way to give feedback unasked, whatever the cards say" do
      sign_in @user
      get root_path
      assert_select "a[data-testid='home-give-feedback'][href='#{evidence_hub_path(give: 1)}']", text: "Give someone feedback →"
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
      ActsAsTenant.with_tenant(@tenant) do
        create(:assessment_level_rating,
          tenant: @tenant, cycle_id: @cycle.cycle_id, person_id: @person.id,
          framework_id: @cycle.framework_id, capability_stable_id: role_capability, level_ordinal: 3,
          self_rated_frequency: "consistent", self_rating_source: "human")
      end

      sign_in @user
      get home_card_path(card: "assessment_progress", key: @cycle.cycle_id)

      assert_response :success
      assert_not_includes response.body, "<html"
      assert_includes response.body, "Q1 2026"
      assert_includes response.body, "Continue self-assessment"
      # CTA must break out of the lazy card frame, not navigate within it.
      assert_includes response.body, 'data-turbo-frame="_top"'
    end

    should "invite a start until the person themselves has rated" do
      # A manager rating flips the row-level progress status to "started",
      # and a carried (seeded) self value isn't a human touch — neither makes
      # the self side started, so the CTA must still say Start (issue #332).
      ActsAsTenant.with_tenant(@tenant) do
        create(:assessment_level_rating,
          tenant: @tenant, cycle_id: @cycle.cycle_id, person_id: @person.id,
          framework_id: @cycle.framework_id, capability_stable_id: role_capability, level_ordinal: 3,
          manager_rated_frequency: "consistent", manager_rating_source: "human")
        create(:assessment_level_rating,
          tenant: @tenant, cycle_id: @cycle.cycle_id, person_id: @person.id,
          framework_id: @cycle.framework_id, capability_stable_id: role_capability, level_ordinal: 3,
          self_rated_frequency: "some", self_rating_source: "seeded")
      end

      sign_in @user
      get home_card_path(card: "assessment_progress", key: @cycle.cycle_id)

      assert_response :success
      assert_includes response.body, "Start self-assessment"
      assert_not_includes response.body, "Continue self-assessment"
    end

    should "tell a person who has finished rating that the next move is the manager's" do
      ActsAsTenant.with_tenant(@tenant) do
        AssessmentCycleProgress.find_by!(cycle_id: @cycle.cycle_id, person_id: @person.id)
          .update!(self_completed_at: Time.current)
      end

      sign_in @user
      get home_card_path(card: "assessment_progress", key: @cycle.cycle_id)

      assert_response :success
      assert_includes response.body, "Ready for alignment"
      assert_includes response.body, "Review self-assessment"
      assert_not_includes response.body, "In progress"
    end

    should "show the alignment phase over a finished self-assessment once alignment starts" do
      ActsAsTenant.with_tenant(@tenant) do
        AssessmentCycleProgress.find_by!(cycle_id: @cycle.cycle_id, person_id: @person.id)
          .update!(self_completed_at: Time.current, status: "aligning")
      end

      sign_in @user
      get home_card_path(card: "assessment_progress", key: @cycle.cycle_id)

      assert_response :success
      assert_includes response.body, "Aligning"
      assert_not_includes response.body, "Ready for alignment"
      assert_not_includes response.body, "Review self-assessment"
    end

    should "ignore ratings outside the assessed role" do
      ActsAsTenant.with_tenant(@tenant) do
        create_out_of_scope_rating(person_id: @person.id, cycle: @cycle, level_ordinal: 3)
      end

      sign_in @user
      get home_card_path(card: "assessment_progress", key: @cycle.cycle_id)

      assert_response :success
      assert_includes response.body, "Start self-assessment"
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
      # CTA must break out of the lazy card frame, not navigate within it.
      assert_includes response.body, 'data-turbo-frame="_top"'
    end

    should "render the evidence-requests card frame for a viewer with a pending incoming request" do
      ActsAsTenant.with_tenant(@tenant) do
        asker = create(:person, tenant: @tenant, name: "Asker One")
        EvidenceRequest.create!(
          id: SecureRandom.uuid_v7, tenant: @tenant, person_id: asker.id,
          framework_id: SecureRandom.uuid_v7, requested_by_id: asker.id,
          requestee_person_id: @person.id, capability_stable_id: SecureRandom.uuid_v7,
          level_ordinal: 2, status: "pending", requested_at: Time.current
        )
      end

      sign_in @user
      get home_card_path(card: "evidence_requests", key: "default")

      assert_response :success
      assert_includes response.body, "Feedback / Evidence requested of you"
      assert_includes response.body, "Asker One"
      assert_includes response.body, "Respond"
      # CTA must break out of the lazy card frame, not navigate within it.
      assert_includes response.body, 'data-turbo-frame="_top"'
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
      # CTA must break out of the lazy card frame, not navigate within it.
      assert_includes response.body, 'data-turbo-frame="_top"'
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

    should "render the recent-activity card frame from the viewer's own activity" do
      ActsAsTenant.with_tenant(@tenant) do
        category = create(:framework_capability_category, framework_id: @cycle.framework_id)
        cap = create(:framework_capability, category_id: category.category_id, name: "Critical Thinking")
        create(:assessment_level_rating,
          tenant: @tenant, cycle_id: @cycle.cycle_id, person_id: @person.id,
          framework_id: @cycle.framework_id, capability_stable_id: cap.stable_id, level_ordinal: 2,
          self_rated_frequency: "consistent", last_self_rated_at: Time.current)
      end

      sign_in @user
      get home_card_path(card: "recent_activity", key: "default")

      assert_response :success
      assert_includes response.body, "Recent activity"
      assert_includes response.body, "self-rated"
      assert_includes response.body, "Critical Thinking"
      # In-frame link must break out to the full page.
      assert_includes response.body, 'data-turbo-frame="_top"'
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

  # A capability the viewer's role reads at their assessed level (L3) —
  # a new one per call, so each rating row has its own cell.
  #
  # @return [String] its stable_id
  def role_capability
    category = create(:framework_capability_category, tenant: @tenant, framework_id: @cycle.framework_id)
    capability = create(:framework_capability, tenant: @tenant, category_id: category.category_id)
    create(:framework_capability_role_binding, tenant: @tenant,
      capability_id: capability.capability_id, role_id: @role.role_id)
    create(:framework_behavioural_expectation, tenant: @tenant,
      capability_id: capability.capability_id, level_ordinal: 3)
    capability.stable_id
  end

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end
