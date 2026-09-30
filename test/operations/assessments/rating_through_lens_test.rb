# frozen_string_literal: true

require "test_helper"

# The rating Operations write through a role lens (ADR-22): the assessee can
# rate any cell the lens role reads, the cell must exist for that role, and
# manager-side writes stay on the cells the record reads until per-role
# alignment exists.
class Operations::Assessments::RatingThroughLensTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @fx = build_role_lens_framework(tenant: @tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @manager_user = create(:user)
      @manager = create(:person, tenant: @tenant, email: @manager_user.email, name: "Morgan")
      @manager_tenant_user = create(:tenant_user, tenant: @tenant, user: @manager_user, person: @manager)
      @user = create(:user)
      @person = create(:person, tenant: @tenant, email: @user.email, name: "Alex", manager: @manager)
      @tenant_user = create(:tenant_user, tenant: @tenant, user: @user, person: @person)
    end
    @assignment, @cycle_id = enrol_in_role_lens_framework(@person, @fx, tenant: @tenant)
    @self_context = AuthorizationContext.new(user: @user, tenant_user: @tenant_user, person: @person)
    @manager_context = AuthorizationContext.new(user: @manager_user, tenant_user: @manager_tenant_user,
                                                person: @manager)
  end

  context Operations::Assessments::RateSelf do
    should "rate a cell only the lens role reads" do
      rate(Operations::Assessments::RateSelf, @self_context, @fx.pm_only, as_role_id: @fx.pm.role_id)
      assert_equal "consistent", rating(@fx.pm_only)&.self_rated_frequency
    end

    should "refuse a cell the lens role doesn't read" do
      error = assert_raises(Operations::Base::ParameterError) do
        rate(Operations::Assessments::RateSelf, @self_context, @fx.e_only, as_role_id: @fx.pm.role_id)
      end
      assert_match(/PM has no expectation/, error.message)
    end

    should "refuse the home role's missing cells without a lens" do
      assert_raises(Operations::Base::ParameterError) do
        rate(Operations::Assessments::RateSelf, @self_context, @fx.pm_only)
      end
    end

    should "refuse a role from another framework or a level the role lacks" do
      assert_raises(Operations::Base::ParameterError) do
        rate(Operations::Assessments::RateSelf, @self_context, @fx.shared, as_role_id: SecureRandom.uuid_v7)
      end
      assert_raises(Operations::Base::ParameterError) do
        rate(Operations::Assessments::RateSelf, @self_context, @fx.shared, level_ordinal: 7)
      end
    end
  end

  context Operations::Assessments::RateAsManager do
    should "rate a shared cell through the lens" do
      rate(Operations::Assessments::RateAsManager, @manager_context, @fx.shared, as_role_id: @fx.pm.role_id)
      assert_equal "consistent", rating(@fx.shared)&.manager_rated_frequency
    end

    should "refuse a cell only another role reads" do
      error = assert_raises(Pundit::NotAuthorizedError) do
        rate(Operations::Assessments::RateAsManager, @manager_context, @fx.pm_only, as_role_id: @fx.pm.role_id)
      end
      assert_match(/per-role alignment/, error.message)
      assert_nil rating(@fx.pm_only)
    end
  end

  context Operations::Assessments::Align do
    should "refuse a cell only another role reads" do
      ActsAsTenant.with_tenant(@tenant) do
        AssessmentCycleProgress.find_by!(cycle_id: @cycle_id, person_id: @person.id).update!(status: "aligning")
      end
      assert_raises(Pundit::NotAuthorizedError) do
        rate(Operations::Assessments::Align, @manager_context, @fx.pm_only, as_role_id: @fx.pm.role_id)
      end
    end
  end

  private

  def rate(operation, context, capability, level_ordinal: 2, **extra)
    ActsAsTenant.with_tenant(@tenant) do
      operation.call(context: context, params: {
        assignment_id: @assignment.id, capability_stable_id: capability.stable_id,
        level_ordinal: level_ordinal, frequency: "consistent", **extra
      })
    end
  end

  def rating(capability)
    ActsAsTenant.with_tenant(@tenant) do
      AssessmentLevelRating.find_by(cycle_id: @cycle_id, person_id: @person.id,
        capability_stable_id: capability.stable_id, level_ordinal: 2)
    end
  end
end
