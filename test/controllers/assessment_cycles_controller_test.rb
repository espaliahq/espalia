# frozen_string_literal: true

require "test_helper"

class AssessmentCyclesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user, password: "password123")
    @member_user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @admin_person = create(:person, tenant: @tenant, email: @admin_user.email, name: "Admin User")
      create(:tenant_user, tenant: @tenant, user: @admin_user, person: @admin_person, role: :admin)
      create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)

      framework_id = SecureRandom.uuid_v7
      @framework = create(:framework_state,
        framework_id: framework_id,
        name: "Engineering Growth",
        current_published_version: 1
      )

      rf = create(:framework_role_family, framework_id: framework_id, name: "Engineering")
      @role = create(:framework_role,
        role_family_id: rf.role_family_id, name: "Software Engineer", code: "E", track: "ic")
      @level = create(:framework_level, role_id: @role.role_id, ordinal: 2, title: "Mid", code: "E2")
    end
  end

  context "as tenant admin" do
    context "GET /assessment_cycles" do
      should "render the index page" do
        sign_in @admin_user
        get assessment_cycles_path

        assert_response :success
        assert_includes response.body, "Assessment Cycles"
      end

      should "render the framework version range when the cycle has rolled forward" do
        ActsAsTenant.with_tenant(@tenant) do
          create(:assessment_cycle, tenant: @tenant, framework_id: @framework.framework_id,
            framework_version: 1, latest_framework_version: 3, name: "Spans v1–v3")
        end

        sign_in @admin_user
        get assessment_cycles_path

        assert_response :success
        assert_includes response.body, "v1–v3"
        assert_not_includes response.body, "v1 v3" # sanity: no stray entity for the dash
      end
    end

    context "GET /assessment_cycles/new" do
      should "render the new cycle form" do
        sign_in @admin_user
        get new_assessment_cycle_path

        assert_response :success
        assert_includes response.body, "Define a new cycle"
        assert_includes response.body, "Engineering Growth"
      end
    end

    context "POST /assessment_cycles" do
      should "define a new cycle and redirect to show" do
        sign_in @admin_user
        assert_difference -> { AssessmentCycle.count }, 1 do
          post assessment_cycles_path, params: {
            assessment_cycle: {
              framework_id: @framework.framework_id,
              name: "Q2 2026 Review",
              cycle_type: "regular"
            }
          }
        end
        cycle = AssessmentCycle.order(:opened_at).last
        assert_redirected_to assessment_cycle_path(cycle)
        assert_equal "Q2 2026 Review", cycle.name
        assert_equal 1, cycle.framework_version
      end

      should "rescue RecordNotUnique when an open cycle already exists" do
        # First create one
        cycle_handler = AssessmentCycles::CommandHandler.new
        ActsAsTenant.with_tenant(@tenant) do
          cycle_handler.define_cycle(
            SecureRandom.uuid_v7, @framework.framework_id,
            "Q1 2026 Review", "regular", 1
          )
        end

        sign_in @admin_user
        assert_no_difference -> { AssessmentCycle.count } do
          post assessment_cycles_path, params: {
            assessment_cycle: {
              framework_id: @framework.framework_id,
              name: "Duplicate cycle",
              cycle_type: "regular"
            }
          }
        end
        assert_redirected_to new_assessment_cycle_path
        follow_redirect!
        assert_match(/open cycle already exists/i, flash[:alert].to_s)
      end

      should "refuse a framework with no published version" do
        ActsAsTenant.with_tenant(@tenant) do
          @framework.update!(current_published_version: 0)
        end

        sign_in @admin_user
        post assessment_cycles_path, params: {
          assessment_cycle: {
            framework_id: @framework.framework_id,
            name: "No version",
            cycle_type: "regular"
          }
        }
        assert_redirected_to new_assessment_cycle_path
        follow_redirect!
        assert_match(/no published version/i, flash[:alert].to_s)
      end
    end

    context "POST /assessment_cycles/:id/close" do
      setup do
        @cycle_id = SecureRandom.uuid_v7
        ActsAsTenant.with_tenant(@tenant) do
          AssessmentCycles::CommandHandler.new.define_cycle(
            @cycle_id, @framework.framework_id,
            "Q1 2026 Review", "regular", 1
          )
        end
        @cycle = ActsAsTenant.with_tenant(@tenant) do
          AssessmentCycle.find_by!(cycle_id: @cycle_id)
        end
      end

      should "close the cycle" do
        sign_in @admin_user
        post close_assessment_cycle_path(@cycle)

        assert_redirected_to assessment_cycle_path(@cycle)
        ActsAsTenant.with_tenant(@tenant) do
          assert_equal "closed", @cycle.reload.status
        end
      end
    end

    context "edit actions on an open cycle" do
      setup do
        @cycle_id = SecureRandom.uuid_v7
        ActsAsTenant.with_tenant(@tenant) do
          AssessmentCycles::CommandHandler.new.define_cycle(
            @cycle_id, @framework.framework_id, "Q1 2026 Review", "regular", 1
          )
          @cycle = AssessmentCycle.find_by!(cycle_id: @cycle_id)
        end
        sign_in @admin_user
      end

      should "rename the cycle" do
        patch rename_assessment_cycle_path(@cycle),
          params: { assessment_cycle: { name: "Renamed Review" } }

        assert_response :success
        ActsAsTenant.with_tenant(@tenant) { assert_equal "Renamed Review", @cycle.reload.name }
      end

      should "reject a blank name" do
        patch rename_assessment_cycle_path(@cycle),
          params: { assessment_cycle: { name: "  " } }

        assert_redirected_to assessment_cycle_path(@cycle)
        ActsAsTenant.with_tenant(@tenant) { assert_equal "Q1 2026 Review", @cycle.reload.name }
      end

      should "change the cycle type" do
        patch change_type_assessment_cycle_path(@cycle),
          params: { assessment_cycle: { cycle_type: "promotion_review" } }

        assert_response :success
        ActsAsTenant.with_tenant(@tenant) { assert_equal "promotion_review", @cycle.reload.cycle_type }
      end

      should "set and clear the planned end date" do
        patch set_planned_end_assessment_cycle_path(@cycle),
          params: { assessment_cycle: { planned_end_at: "2026-06-30" } }
        assert_response :success
        ActsAsTenant.with_tenant(@tenant) do
          assert_equal Date.new(2026, 6, 30), @cycle.reload.planned_end_at
        end

        patch set_planned_end_assessment_cycle_path(@cycle),
          params: { assessment_cycle: { planned_end_at: "" } }
        assert_response :success
        ActsAsTenant.with_tenant(@tenant) { assert_nil @cycle.reload.planned_end_at }
      end
    end

    context "edit actions on a closed cycle" do
      setup do
        @cycle_id = SecureRandom.uuid_v7
        ActsAsTenant.with_tenant(@tenant) do
          handler = AssessmentCycles::CommandHandler.new
          handler.define_cycle(@cycle_id, @framework.framework_id, "Q1 2026 Review", "regular", 1)
          handler.close_cycle(@cycle_id)
          @cycle = AssessmentCycle.find_by!(cycle_id: @cycle_id)
        end
        sign_in @admin_user
      end

      should "refuse to rename a closed cycle" do
        patch rename_assessment_cycle_path(@cycle),
          params: { assessment_cycle: { name: "Too late" } }

        assert_redirected_to assessment_cycle_path(@cycle)
        follow_redirect!
        assert_match(/closed cycles can't be edited/i, flash[:alert].to_s)
        ActsAsTenant.with_tenant(@tenant) { assert_equal "Q1 2026 Review", @cycle.reload.name }
      end
    end
  end

  context "as tenant member" do
    should "deny GET /assessment_cycles" do
      sign_in @member_user
      get assessment_cycles_path

      assert_redirected_to root_path
      assert_match(/not authorized/i, flash[:alert].to_s)
    end

    should "deny GET /assessment_cycles/new" do
      sign_in @member_user
      get new_assessment_cycle_path

      assert_redirected_to root_path
      assert_match(/not authorized/i, flash[:alert].to_s)
    end

    should "deny POST /assessment_cycles" do
      sign_in @member_user
      post assessment_cycles_path, params: {
        assessment_cycle: {
          framework_id: @framework.framework_id,
          name: "Should fail",
          cycle_type: "regular"
        }
      }

      assert_redirected_to root_path
      assert_equal 0, AssessmentCycle.count
    end

    should "deny PATCH rename" do
      cycle_id = SecureRandom.uuid_v7
      ActsAsTenant.with_tenant(@tenant) do
        AssessmentCycles::CommandHandler.new.define_cycle(
          cycle_id, @framework.framework_id, "Q1 2026 Review", "regular", 1
        )
        @cycle = AssessmentCycle.find_by!(cycle_id: cycle_id)
      end

      sign_in @member_user
      patch rename_assessment_cycle_path(@cycle),
        params: { assessment_cycle: { name: "Hacked" } }

      assert_redirected_to root_path
      ActsAsTenant.with_tenant(@tenant) { assert_equal "Q1 2026 Review", @cycle.reload.name }
    end
  end

  context "unauthenticated" do
    should "redirect to sign in" do
      get assessment_cycles_path
      assert_redirected_to new_user_session_path
    end
  end

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end
