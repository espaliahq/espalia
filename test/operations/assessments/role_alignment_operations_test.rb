# frozen_string_literal: true

require "test_helper"

# Start / complete / re-open alignment through the Operations the web and MCP
# share (ADR-22): against the home role by default, or a lens role, with the
# completion gate counted over that role's own cells.
class Operations::Assessments::RoleAlignmentOperationsTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @fx = build_role_lens_framework(tenant: @tenant)
    @manager_user = create(:user)
    @manager = create(:person, tenant: @tenant, email: @manager_user.email, name: "Morgan")
    manager_tu = create(:tenant_user, tenant: @tenant, user: @manager_user, person: @manager)
    @person = create(:person, tenant: @tenant, manager: @manager, name: "Alex")
    @delegate_user = create(:user)
    @delegate = create(:person, tenant: @tenant, email: @delegate_user.email)
    delegate_tu = create(:tenant_user, tenant: @tenant, user: @delegate_user, person: @delegate)
    @assignment, @cycle_id = enrol_in_role_lens_framework(@person, @fx, tenant: @tenant)
    create(:manager_assessment_delegation, tenant: @tenant, person_id: @person.id,
           framework_id: @fx.framework_id, delegate_person_id: @delegate.id)
    @manager_ctx = AuthorizationContext.new(user: @manager_user, tenant_user: manager_tu, person: @manager)
    @delegate_ctx = AuthorizationContext.new(user: @delegate_user, tenant_user: delegate_tu, person: @delegate)
    @pm = { as_role_id: @fx.pm.role_id, as_level_ordinal: 2 }
  end

  teardown { ActsAsTenant.current_tenant = nil }

  def call(operation, context: @manager_ctx, **params)
    operation.call(context: context, params: { assignment_id: @assignment.id, **params })
  end

  def rate_both(capability, frequency = "consistent")
    handler = PersonDevelopment::CommandHandler.new
    handler.rate_self(@person.id, @fx.framework_id, capability.stable_id,
                      level_ordinal: 2, frequency: frequency, cycle_id: @cycle_id)
    handler.rate_as_manager(@person.id, @fx.framework_id, capability.stable_id,
                            level_ordinal: 2, frequency: frequency, cycle_id: @cycle_id, rated_by_id: @manager.id)
  end

  def progress
    AssessmentCycleProgress.find_by!(cycle_id: @cycle_id, person_id: @person.id)
  end

  context Operations::Assessments::StartAlignment do
    should "start against a lens role without touching the home lifecycle" do
      rate_both(@fx.pm_only)

      result = call(Operations::Assessments::StartAlignment, **@pm)

      assert_equal({ role_id: @fx.pm.role_id, role_code: "PM", level_ordinal: 2, home: false, status: "aligning" },
                   result.slice(:role_id, :role_code, :level_ordinal, :home, :status))
      assert_not_equal "aligning", progress.status
      aligned = AssessmentLevelRating.find_by(cycle_id: @cycle_id, capability_stable_id: @fx.pm_only.stable_id)
      assert_equal "consistent", aligned.aligned_frequency, "the agreed PM2 cell aligned on start"
    end

    should "start against the home role by default" do
      rate_both(@fx.e_only)

      result = call(Operations::Assessments::StartAlignment)

      assert result[:home]
      assert_equal "aligning", progress.status
    end

    should "refuse a delegate" do
      assert_raises(Pundit::NotAuthorizedError) do
        call(Operations::Assessments::StartAlignment, context: @delegate_ctx, **@pm)
      end
    end

    should "refuse a role the framework doesn't have" do
      assert_raises(Operations::Base::ParameterError) do
        call(Operations::Assessments::StartAlignment, as_role_id: SecureRandom.uuid_v7)
      end
    end
  end

  context Operations::Assessments::Get do
    should "list every started alignment, home included, without a lens" do
      assert_empty call(Operations::Assessments::Get)[:current_cycle][:alignments]

      call(Operations::Assessments::StartAlignment, **@pm)
      rate_both(@fx.e_only)
      call(Operations::Assessments::StartAlignment)

      alignments = call(Operations::Assessments::Get)[:current_cycle][:alignments]
      assert_equal [ [ "E", 2, "aligning", true ], [ "PM", 2, "aligning", false ] ],
                   alignments.map { |a| a.values_at(:role_code, :level_ordinal, :status, :home) }
    end
  end

  context Operations::Assessments::CompleteAlignment do
    setup { call(Operations::Assessments::StartAlignment, **@pm) }

    should "gate on that role's own current-level cells" do
      error = assert_raises(Operations::Base::ParameterError) do
        call(Operations::Assessments::CompleteAlignment, **@pm)
      end
      assert_match(/2 current-level capabilities still need an agreed rating/, error.message)
    end

    should "complete once every PM2 cell is agreed, E2's unagreed cells notwithstanding" do
      [ @fx.pm_only, @fx.shared ].each do |capability|
        call(Operations::Assessments::Align, capability_stable_id: capability.stable_id, level_ordinal: 2,
             frequency: "some", as_role_id: @fx.pm.role_id)
      end

      result = call(Operations::Assessments::CompleteAlignment, **@pm)

      assert_equal "aligned", result[:status]
      assert_equal "aligned", AssessmentCycleRoleAlignment.find_by!(role_id: @fx.pm.role_id).status
    end

    should "re-open the lens role's alignment" do
      [ @fx.pm_only, @fx.shared ].each do |capability|
        call(Operations::Assessments::Align, capability_stable_id: capability.stable_id, level_ordinal: 2,
             frequency: "some", as_role_id: @fx.pm.role_id)
      end
      call(Operations::Assessments::CompleteAlignment, **@pm)

      result = call(Operations::Assessments::ReopenAlignment, as_role_id: @fx.pm.role_id, as_level_ordinal: 3)

      assert_equal "aligning", result[:status]
      assert_not result[:home]
      assert_equal 2, result[:level_ordinal], "the conversation's level, not the lens level the call named"
    end
  end
end
