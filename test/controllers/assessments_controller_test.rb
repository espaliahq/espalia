# frozen_string_literal: true

require "test_helper"

class AssessmentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    @user = create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) do
      @person = create(:person, tenant: @tenant, email: @user.email, name: "Test User")
      create(:tenant_user, tenant: @tenant, user: @user, person: @person)

      # Build framework via factories
      framework_id = SecureRandom.uuid_v7
      @framework = create(:framework_state, framework_id: framework_id, name: "Engineering Growth")

      rf = create(:framework_role_family, framework_id: framework_id, name: "Engineering")
      @role = create(:framework_role,
        role_family_id: rf.role_family_id, name: "Software Engineer", code: "E", track: "ic")
      @level = create(:framework_level, role_id: @role.role_id, ordinal: 2, title: "Mid", code: "E2")
      create(:framework_level, role_id: @role.role_id, ordinal: 1, title: "Junior", code: "E1")

      cat = create(:framework_capability_category, framework_id: framework_id, name: "Thinking", ordinal: 1)
      @cap = create(:framework_capability, category_id: cat.category_id, name: "Critical Thinking")
      create(:framework_capability_role_binding,
        capability_id: @cap.capability_id, role_id: @role.role_id, weight: 1.0)
      create(:framework_behavioural_expectation,
        capability_id: @cap.capability_id, level_ordinal: 1, description: "Asks good questions")
      create(:framework_behavioural_expectation,
        capability_id: @cap.capability_id, level_ordinal: 2, description: "Synthesises information")

      # Create assignment + define cycle + enroll via event projection
      handler = PersonDevelopment::CommandHandler.new
      cycle_handler = AssessmentCycles::CommandHandler.new
      handler.assign_to_framework(@person.id, framework_id, @role.role_id, @level.level_id)

      @cycle_id = SecureRandom.uuid_v7
      cycle_handler.define_cycle(@cycle_id, framework_id, "Q1 2026", "regular", 1)
      cycle_handler.enroll(@cycle_id, @person.id)

      @assignment = PersonFrameworkAssignment.for_person(@person.id).first
    end
  end

  context "GET /assessments" do
    should "render index with framework assignments" do
      sign_in @user
      get assessments_path

      assert_response :success
      assert_includes response.body, "Engineering Growth"
      assert_includes response.body, "My Assessments"
      # Untouched enrollment → the CTA invites a start, agreeing with the
      # "Not started" Self chip (issue #332).
      assert_includes response.body, "Start self-assessment"
    end

    should "flip the own-card CTA to Continue once a self rating lands" do
      # A second current-level capability, so one rating leaves the
      # self-assessment unfinished.
      ActsAsTenant.with_tenant(@tenant) do
        other = create(:framework_capability, category_id: @cap.category_id, name: "Execution")
        create(:framework_capability_role_binding, capability_id: other.capability_id, role_id: @role.role_id)
        create(:framework_behavioural_expectation, capability_id: other.capability_id, level_ordinal: 2)
      end
      rate(@cap, "consistent")

      sign_in @user
      get assessments_path

      assert_response :success
      assert_includes response.body, "Continue self-assessment"
      assert_not_includes response.body, "Start self-assessment"
    end

    should "offer a review once the self-assessment is ready for alignment" do
      rate(@cap, "consistent")

      sign_in @user
      get assessments_path

      assert_response :success
      assert_includes response.body, "Ready for alignment"
      assert_includes response.body, "Review self-assessment"
      assert_not_includes response.body, "Continue self-assessment"
    end

    should "ignore ratings outside the assessed role" do
      ActsAsTenant.with_tenant(@tenant) do
        create_out_of_scope_rating(person_id: @person.id, cycle: AssessmentCycle.find_by!(cycle_id: @cycle_id),
          level_ordinal: 2)
      end

      sign_in @user
      get assessments_path

      assert_response :success
      assert_includes response.body, "Start self-assessment"
    end

    should "redirect unauthenticated users to sign in" do
      get assessments_path
      assert_redirected_to new_user_session_path
    end

    should "issue a bounded number of cycle queries regardless of assignment count" do
      # Seed multiple direct reports assigned to the framework. Because an
      # open cycle already exists (from setup), the
      # AssessmentCycles::SyncHandlers::AutoEnrollNewAssignments handler
      # auto-enrolls each new assignment — no explicit cycle_handler.enroll
      # call is needed. The index should then render several assignment
      # cards, each with an open cycle. Without batch loading this would
      # trigger one cycle lookup per card (N+1).
      ActsAsTenant.with_tenant(@tenant) do
        manager = @person
        handler = PersonDevelopment::CommandHandler.new

        3.times do |i|
          report_user = create(:user, password: "password123")
          report = create(:person,
            tenant: @tenant, email: report_user.email, name: "Report #{i}", manager: manager)
          create(:tenant_user, tenant: @tenant, user: report_user, person: report)
          handler.assign_to_framework(
            report.id, @framework.framework_id, @role.role_id, @level.level_id
          )
        end
      end

      sign_in @user

      queries = []
      callback = ->(_n, _s, _f, _i, payload) do
        queries << payload[:sql] unless payload[:name] == "SCHEMA" || payload[:sql] =~ /SAVEPOINT/
      end

      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        get assessments_path
      end
      assert_response :success

      # The old N+1 pattern issued one `SELECT ... FROM "assessment_cycles" ...`
      # per rendered assignment card (via PersonFrameworkAssignment#current_open_cycle).
      # The batch preload uses `FROM "assessment_cycle_enrollments" LEFT OUTER JOIN
      # "assessment_cycles"`, so queries with `FROM "assessment_cycles"` as the primary
      # table should be zero. Policy scalar queries join THROUGH assessment_cycles but
      # SELECT FROM person_framework_assignments, so they don't match either.
      primary_cycle_queries = queries.select { |q| q =~ /FROM "assessment_cycles"/ }
      assert_equal 0, primary_cycle_queries.size,
        "expected 0 per-assignment cycle queries, got #{primary_cycle_queries.size}: #{primary_cycle_queries.inspect}"
    end
  end

  context "GET /assessments/:id" do
    should "render assessment matrix for assigned framework" do
      sign_in @user
      get assessment_path(@assignment)

      assert_response :success
      assert_select "h1", text: "Mid"
      assert_select "span.font-mono", text: "E2"
      assert_includes response.body, "Critical Thinking"
      assert_includes response.body, "assessment-matrix"
      assert_includes response.body, "scoring-panel"
    end

    should "show frequency selectors" do
      sign_in @user
      get assessment_path(@assignment)

      assert_response :success
      assert_includes response.body, "Some"
      assert_includes response.body, "Most"
      assert_includes response.body, "Consistently"
    end

    should "redirect if person not assigned to framework" do
      sign_in @user
      get assessment_path("nonexistent-id")

      assert_redirected_to assessments_path
    end

    should "redirect unauthenticated users to sign in" do
      get assessment_path(@assignment)
      assert_redirected_to new_user_session_path
    end
  end

  context "as manager" do
    setup do
      @manager_user = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) do
        @manager = create(:person, tenant: @tenant, email: @manager_user.email, name: "Manager")
        create(:tenant_user, tenant: @tenant, user: @manager_user, person: @manager)
        @person.update!(manager: @manager)
      end
    end

    should "render manager assessment view for direct report" do
      sign_in @manager_user
      get assessment_path(@assignment)

      assert_response :success
      assert_includes response.body, @person.name
      assert_includes response.body, "assessment-matrix"
    end

    should "show team assessments section on index" do
      sign_in @manager_user
      get assessments_path

      assert_response :success
      assert_includes response.body, "Team Assessments"
      assert_includes response.body, @person.name
    end

    should "not show skip-level section to a manager with no skip-level reports" do
      sign_in @manager_user
      get assessments_path

      assert_response :success
      assert_not_includes response.body, "Skip-Level Assessments"
    end

    should "show skip-level assessments section to the manager's manager" do
      skip_user = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) do
        grand_manager = create(:person, tenant: @tenant, email: skip_user.email, name: "Grand Manager")
        create(:tenant_user, tenant: @tenant, user: skip_user, person: grand_manager)
        @manager.update!(manager: grand_manager)
      end

      sign_in skip_user
      get assessments_path

      assert_response :success
      assert_includes response.body, "Skip-Level Assessments"
      assert_includes response.body, @person.name
      # The direct-report team section only renders when a direct report has
      # an assignment — the manager in between has none here.
      assert_not_includes response.body, "Team Assessments"
    end

    should "paginate the skip-level section beyond #{AssessmentsController::SKIP_LEVEL_PAGE_SIZE} assignments" do
      skip_user = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) do
        grand_manager = create(:person, tenant: @tenant, email: skip_user.email, name: "Grand Manager")
        create(:tenant_user, tenant: @tenant, user: skip_user, person: grand_manager)
        @manager.update!(manager: grand_manager)

        handler = PersonDevelopment::CommandHandler.new
        AssessmentsController::SKIP_LEVEL_PAGE_SIZE.times do |i|
          extra = create(:person, tenant: @tenant, name: "Extra Skip #{i}", manager: @manager)
          handler.assign_to_framework(extra.id, @framework.framework_id, @role.role_id, @level.level_id)
        end
      end

      sign_in skip_user
      get assessments_path

      assert_response :success
      assert_includes response.body, "Page 1 of 2"
      # The pager's dead end is an inactive control, not plain text — that is
      # what exempts its muted colour from 1.4.3 (#323).
      assert_select "#skip-level-assessments span[role='link'][aria-disabled='true']", text: /Prev/
      # 13 skip-level assignments, ordered by id (creation order): the last
      # one created falls on page 2.
      assert_not_includes response.body, "Extra Skip #{AssessmentsController::SKIP_LEVEL_PAGE_SIZE - 1}"

      get assessments_path(skip_page: 2)

      assert_response :success
      assert_includes response.body, "Page 2 of 2"
      assert_includes response.body, "Extra Skip #{AssessmentsController::SKIP_LEVEL_PAGE_SIZE - 1}"
      assert_not_includes response.body, "Extra Skip 0"
    end

    should "render read-only manager view for a skip-level manager" do
      skip_user = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) do
        grand_manager = create(:person, tenant: @tenant, email: skip_user.email, name: "Grand Manager")
        create(:tenant_user, tenant: @tenant, user: skip_user, person: grand_manager)
        @manager.update!(manager: grand_manager)
      end

      sign_in skip_user
      get assessment_path(@assignment)

      assert_response :success
      assert_includes response.body, @person.name
      # View-only: no interactive manager-rating form may render for a
      # chain ancestor who is not the recorded reporting manager.
      assert_not_includes response.body, assessment_manager_ratings_path(@assignment)
      # The priming hero renders passive copy — no "Rate …" imperative or
      # rate-next CTA for a viewer without rating authority.
      assert_includes response.body, "No score for #{@person.name.split.first} yet"
      assert_not_includes response.body, "Rate next capability"
    end

    should "keep the imperative priming hero for the direct manager" do
      sign_in @manager_user
      get assessment_path(@assignment)

      assert_response :success
      assert_includes response.body, "Rate #{@person.name.split.first} to see their score"
      assert_includes response.body, "Rate next capability"
    end

    should "keep the manager-rating form interactive for the direct manager" do
      sign_in @manager_user
      get assessment_path(@assignment)

      assert_response :success
      assert_includes response.body, assessment_manager_ratings_path(@assignment)
    end

    should "render the read-only manager view for a tenant admin outside the chain" do
      admin_user = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) do
        admin = create(:person, tenant: @tenant, email: admin_user.email, name: "HR Admin")
        create(:tenant_user, tenant: @tenant, user: admin_user, person: admin, role: :admin)
      end

      sign_in admin_user
      get assessment_path(@assignment)

      assert_response :success
      assert_includes response.body, @person.name
      # No manager-rating endpoint rendered — the admin views, never rates.
      assert_not_includes response.body, assessment_manager_ratings_path(@assignment)
    end

    should "redirect if not manager and not assignee" do
      other_user = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) do
        other = create(:person, tenant: @tenant, email: other_user.email, name: "Other")
        create(:tenant_user, tenant: @tenant, user: other_user, person: other)
      end

      sign_in other_user
      get assessment_path(@assignment)

      assert_response :redirect
      assert_equal "You are not authorized to perform this action.", flash[:alert]
    end
  end

  context "GET /assessments/:id/matrix" do
    should "render Turbo Frame without layout" do
      sign_in @user
      get matrix_assessment_path(@assignment)

      assert_response :success
      assert_includes response.body, "assessment-matrix"
      assert_not_includes response.body, "<html"
    end

    should "render all category sections in the matrix" do
      sign_in @user
      get matrix_assessment_path(@assignment)

      assert_response :success
      assert_includes response.body, "Thinking"
    end

    should "default to first category when no category param" do
      sign_in @user
      get matrix_assessment_path(@assignment)

      assert_response :success
      # Should show the capabilities from Thinking category
      assert_includes response.body, "Critical Thinking"
    end

    should "fall back to first category for invalid category param" do
      sign_in @user
      get matrix_assessment_path(@assignment, category: "nonexistent")

      assert_response :success
      assert_includes response.body, "Critical Thinking"
    end
  end

  def get_card(**params)
    get capability_card_assessment_path(@assignment, **params), headers: { "Accept" => "text/vnd.turbo-stream.html" }
  end

  context "GET /assessments/:id/capability_card" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        @other_cap = create(:framework_capability, category_id: @cap.category_id, name: "Execution")
        create(:framework_capability_role_binding, capability_id: @other_cap.capability_id, role_id: @role.role_id)
        create(:framework_behavioural_expectation,
          capability_id: @other_cap.capability_id, level_ordinal: 2, description: "Ships reliably")
      end
    end

    should "replace just that card, at the level asked for" do
      sign_in @user
      get_card(capability: @cap.stable_id, level_ordinal: 1)

      assert_response :success
      assert_equal "text/vnd.turbo-stream.html", response.media_type
      assert_includes response.body, %(action="replace" target="capability-card-#{@cap.stable_id}")
      assert_includes response.body, "Asks good questions"
      assert_not_includes response.body, "Synthesises information"
      assert_not_includes response.body, "Execution", "no other card"
      assert_not_includes response.body, %(data-controller="matrix"), "no matrix wrapper"
      assert_not_includes response.body, "<section", "no category section around the card"
    end

    should "default to the person's level" do
      sign_in @user
      get_card(capability: @cap.stable_id)

      assert_response :success
      assert_includes response.body, "Synthesises information"
    end

    should "404 for a capability the matrix doesn't show" do
      sign_in @user
      get_card(capability: SecureRandom.uuid_v7)

      assert_response :not_found
    end

    should "deny a viewer who may not see the assessment" do
      other_user = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) do
        other = create(:person, tenant: @tenant, email: other_user.email, name: "Outsider")
        create(:tenant_user, tenant: @tenant, user: other_user, person: other)
      end
      sign_in other_user
      get_card(capability: @cap.stable_id)

      assert_response :redirect
      assert_not_includes response.body, "Asks good questions"
    end
  end

  context "GET /assessments/:id/matrix — unauthorized" do
    setup do
      @other_user = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) do
        other = create(:person, tenant: @tenant, email: @other_user.email, name: "Outsider")
        create(:tenant_user, tenant: @tenant, user: @other_user, person: other)
      end
    end

    # A Turbo Frame fetch can't follow a redirect — it must get the requested
    # frame back, or Turbo logs "did not contain the expected <turbo-frame>"
    # and the section breaks. Denied frame requests render a recovery frame.
    should "render the recovery frame (not redirect) for a Turbo Frame request" do
      sign_in @other_user
      get matrix_assessment_path(@assignment), headers: { "Turbo-Frame" => "assessment-matrix" }

      assert_response :success
      assert_includes response.body, "assessment-matrix"
      assert_includes response.body, "Reload"
      assert_not_includes response.body, "<html"
    end

    should "still redirect for a normal (non-frame) request" do
      sign_in @other_user
      get matrix_assessment_path(@assignment)

      assert_response :redirect
    end

    should "never link the recovery Reload to an off-site Referer" do
      sign_in @other_user
      get matrix_assessment_path(@assignment), headers: {
        "Turbo-Frame" => "assessment-matrix",
        "Referer" => "https://evil.example.com/phish"
      }

      assert_response :success
      assert_not_includes response.body, "evil.example.com"
      assert_includes response.body, %(href="#{root_path}")
    end
  end

  context "GET /assessments/:id/matrix with multiple categories" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        # Add a second category
        cat2 = create(:framework_capability_category,
          framework_id: @framework.framework_id, name: "Delivering", ordinal: 2)
        @cap2 = create(:framework_capability, category_id: cat2.category_id, name: "Execution")
        create(:framework_capability_role_binding,
          capability_id: @cap2.capability_id, role_id: @role.role_id, weight: 1.0)
        create(:framework_behavioural_expectation,
          capability_id: @cap2.capability_id, level_ordinal: 1, description: "Ships features reliably")
        @cat2_id = cat2.category_id
      end
    end

    should "render only the selected category" do
      sign_in @user
      get matrix_assessment_path(@assignment, category: @cat2_id)

      assert_response :success
      # Should show Execution from Delivering category
      assert_includes response.body, "Execution"
      # Should NOT show capabilities from the other category in the table body
      # (tabs will still mention both categories)
    end

    should "render category chips with aria-current on the show page" do
      sign_in @user
      get assessment_path(@assignment)

      assert_response :success
      assert_includes response.body, "category-tabs"
      assert_includes response.body, "Thinking"
    end

    should "omit archived categories from the rendered matrix" do
      ActsAsTenant.with_tenant(@tenant) do
        FrameworkState::CapabilityCategory.find_by!(category_id: @cat2_id).update!(status: "archived")
      end

      sign_in @user
      get matrix_assessment_path(@assignment)

      assert_response :success
      assert_not_includes response.body, "Delivering",
        "archived category name should not appear in the matrix"
    end
  end

  context "GET /assessments/:id/scoring — coverage gating" do
    setup do
      # Base setup has one current-level (E2) capability. Add two more so the
      # current-level denominator is 3 and the 50% unlock threshold lands at 2
      # rated — making the boundary non-degenerate.
      ActsAsTenant.with_tenant(@tenant) do
        cat = FrameworkState::CapabilityCategory.find_by!(framework_id: @framework.framework_id, name: "Thinking")
        @extra_caps = [ "Communication", "Ownership" ].map do |name|
          cap = create(:framework_capability, category_id: cat.category_id, name: name)
          create(:framework_capability_role_binding,
            capability_id: cap.capability_id, role_id: @role.role_id, weight: 1.0)
          create(:framework_behavioural_expectation,
            capability_id: cap.capability_id, level_ordinal: 1, description: "L1 #{name}")
          create(:framework_behavioural_expectation,
            capability_id: cap.capability_id, level_ordinal: 2, description: "L2 #{name}")
          cap
        end
      end
    end

    should "show the priming hero with no ratings" do
      sign_in @user
      get scoring_assessment_path(@assignment)

      assert_response :success
      assert_includes response.body, "Rate yourself to see your score"
      assert_includes response.body, "Score unlocks at 2"
      assert_not_includes response.body, "demonstrated"
    end

    should "stay primed below the 50% threshold (1 of 3 rated)" do
      rate(@cap, "consistent")

      sign_in @user
      get scoring_assessment_path(@assignment)

      assert_response :success
      assert_includes response.body, "Score unlocks at 2"
      assert_includes response.body, "1/3"
      assert_not_includes response.body, "demonstrated"
    end

    should "unlock scoring at the 50% threshold with a coverage chip (2 of 3 rated)" do
      rate(@cap, "consistent")
      rate(@extra_caps.first, "consistent")

      sign_in @user
      get scoring_assessment_path(@assignment)

      assert_response :success
      assert_includes response.body, "demonstrated"
      assert_includes response.body, "2 of 3 rated"
      assert_not_includes response.body, "Rate yourself to see your score"
    end

    should "drop the coverage chip once fully rated" do
      @extra_caps.each { |c| rate(c, "consistent") }
      rate(@cap, "consistent")

      sign_in @user
      get scoring_assessment_path(@assignment)

      assert_response :success
      assert_includes response.body, "demonstrated"
      assert_not_includes response.body, "of 3 rated"
    end
  end

  private

  def rate(capability, frequency)
    ActsAsTenant.with_tenant(@tenant) do
      PersonDevelopment::CommandHandler.new.rate_self(
        @person.id, @framework.framework_id, capability.stable_id,
        level_ordinal: 2, frequency: frequency, cycle_id: @cycle_id
      )
    end
  end

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end
