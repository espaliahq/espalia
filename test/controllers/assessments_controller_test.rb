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
      # The batch preload uses `FROM "assessment_cycle_participants" LEFT OUTER JOIN
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
      assert_includes response.body, "Mid"
      assert_includes response.body, "E2"
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

    should "render category tabs" do
      sign_in @user
      get matrix_assessment_path(@assignment)

      assert_response :success
      assert_includes response.body, "category-tabs"
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

    should "highlight active tab with aria-current" do
      sign_in @user
      get matrix_assessment_path(@assignment, category: @cat2_id)

      assert_response :success
      assert_includes response.body, 'aria-current="page"'
    end
  end

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end
