# frozen_string_literal: true

require "test_helper"

# The MCP read tools read through a role lens (ADR-22): the payload says
# which lens it read against and which roles read each capability, the
# honesty gates still hold, and the assessee never receives a manager rating
# on a cell only the lens role reads.
class Operations::Assessments::ReadThroughLensTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @fx = build_role_lens_framework(tenant: @tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @user = create(:user)
      @person = create(:person, tenant: @tenant, email: @user.email, name: "Alex")
      @tenant_user = create(:tenant_user, tenant: @tenant, user: @user, person: @person)
    end
    @assignment, @cycle_id = enrol_in_role_lens_framework(@person, @fx, tenant: @tenant)
    @context = AuthorizationContext.new(user: @user, tenant_user: @tenant_user, person: @person)
    @pm_lens = { as_role_id: @fx.pm.role_id, as_level_ordinal: 2 }
  end

  context Operations::Assessments::Get do
    should "name the lens and the roles that read each capability" do
      payload = get(**@pm_lens)

      assert_equal({ role_id: @fx.pm.role_id, role_code: "PM", level_ordinal: 2, home: false,
                     cycle_id: @cycle_id, past_cycle: false },
                   payload[:scoring][:lens])
      assert_equal "PM2", payload[:scoring][:scale][:assessed_level]
      capabilities = payload[:framework][:categories].flat_map { |c| c[:capabilities] }.index_by { |c| c[:name] }
      assert_equal({ home: false, lens: true }, capabilities["Roadmapping"][:in_role])
      assert_equal({ home: true, lens: false }, capabilities["Systems Design"][:in_role])
      assert_equal({ home: true, lens: true }, capabilities["Critical Thinking"][:in_role])
    end

    should "read the record without lens params" do
      assert_equal true, get.dig(:scoring, :lens, :home)
    end

    should "keep the coverage gate under a lens" do
      scoring = get(**@pm_lens)[:scoring]
      assert_equal false, scoring[:scored]
      assert_equal "coverage_below_threshold", scoring[:unscored_reason]
    end

    should "refuse a role or level the framework doesn't have" do
      assert_raises(Operations::Base::ParameterError) { get(as_role_id: SecureRandom.uuid_v7) }
      assert_raises(Operations::Base::ParameterError) { get(as_level_ordinal: 9) }
    end
  end

  context Operations::Assessments::CapabilityGet do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        [ @fx.shared, @fx.pm_only ].each do |capability|
          create(:assessment_level_rating, tenant: @tenant, cycle_id: @cycle_id, person_id: @person.id,
            framework_id: @fx.framework_id, capability_stable_id: capability.stable_id, level_ordinal: 2,
            self_rated_frequency: "some", manager_rated_frequency: "consistent", aligned_frequency: "occasional")
        end
        AssessmentCycleProgress.find_by!(cycle_id: @cycle_id, person_id: @person.id).update!(status: "aligned")
      end
    end

    should "keep a manager rating private on a cell only the lens role reads" do
      payload = capability_get(@fx.pm_only, **@pm_lens)

      ratings = payload[:expectations].find { |e| e[:level_ordinal] == 2 }[:ratings]
      assert_equal "some", ratings[:self]
      assert_nil ratings[:manager]
      assert_nil ratings[:aligned]
      assert_equal({ home: false, lens: true }, payload[:in_role])
      assert_equal false, payload[:lens][:home]
    end

    should "show what home alignment disclosed on a shared cell" do
      ratings = capability_get(@fx.shared, **@pm_lens)[:expectations].find { |e| e[:level_ordinal] == 2 }[:ratings]
      assert_equal "consistent", ratings[:manager]
      assert_equal "occasional", ratings[:aligned]
    end
  end

  private

  def get(**lens)
    call(Operations::Assessments::Get, assignment_id: @assignment.id, **lens)
  end

  def capability_get(capability, **lens)
    call(Operations::Assessments::CapabilityGet, assignment_id: @assignment.id,
         capability_id: capability.stable_id, **lens)
  end

  def call(operation, **params)
    ActsAsTenant.with_tenant(@tenant) { operation.call(context: @context, params: params) }
  end
end
