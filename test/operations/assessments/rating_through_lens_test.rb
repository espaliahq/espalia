# frozen_string_literal: true

require "test_helper"

# The rating Operations write through a role lens (ADR-22): either party can
# rate any cell the lens role reads, the cell must exist for that role, and a
# cell some started alignment reads is frozen — whichever lens the write is
# made through.
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

  context "provenance" do
    should "stamp the lens role on a rating made through it, and nothing on the home role" do
      rate(Operations::Assessments::RateSelf, @self_context, @fx.pm_only, as_role_id: @fx.pm.role_id)
      rate(Operations::Assessments::RateSelf, @self_context, @fx.e_only)
      assert_equal @fx.pm.role_id, rating(@fx.pm_only).self_rated_via_role_id
      assert_nil rating(@fx.e_only).self_rated_via_role_id
    end

    should "follow a revision, and clear with the rating" do
      rate(Operations::Assessments::RateSelf, @self_context, @fx.shared, as_role_id: @fx.pm.role_id)
      rate(Operations::Assessments::RateSelf, @self_context, @fx.shared, frequency: "some")
      assert_nil rating(@fx.shared).self_rated_via_role_id, "revised on the home role"

      rate(Operations::Assessments::RateAsManager, @manager_context, @fx.shared, as_role_id: @fx.pm.role_id)
      assert_equal @fx.pm.role_id, rating(@fx.shared).manager_rated_via_role_id
    end

    should "name the lens in the activity feed" do
      rate(Operations::Assessments::RateSelf, @self_context, @fx.pm_only, as_role_id: @fx.pm.role_id)
      entry = ActsAsTenant.with_tenant(@tenant) do
        Assessments::ActivityFeedQuery.new(assignment: @assignment, context: :self, viewer_person_id: @person.id,
                                           viewer_sees_all: true, alignment_started: false).call
          .find { |e| e.kind == "self_rated" }
      end
      assert_equal "PM2", entry.payload[:via_role_code]
    end
  end

  context Operations::Assessments::RateAsManager do
    should "rate a shared cell through the lens" do
      rate(Operations::Assessments::RateAsManager, @manager_context, @fx.shared, as_role_id: @fx.pm.role_id)
      assert_equal "consistent", rating(@fx.shared)&.manager_rated_frequency
    end

    should "rate a cell only another role reads" do
      rate(Operations::Assessments::RateAsManager, @manager_context, @fx.pm_only, as_role_id: @fx.pm.role_id)
      assert_equal "consistent", rating(@fx.pm_only)&.manager_rated_frequency
    end

    should "refuse a cell a started alignment froze, naming the role" do
      start_alignment(@fx.pm)

      error = assert_raises(Pundit::NotAuthorizedError) do
        rate(Operations::Assessments::RateAsManager, @manager_context, @fx.shared)
      end
      assert_equal "Frozen — alignment against PM2 has started", error.message
      assert_nothing_raised do
        rate(Operations::Assessments::RateAsManager, @manager_context, @fx.e_only)
      end
    end
  end

  context Operations::Assessments::Align do
    should "refuse a cell no alignment in progress reads" do
      ActsAsTenant.with_tenant(@tenant) do
        AssessmentCycleProgress.find_by!(cycle_id: @cycle_id, person_id: @person.id).update!(status: "aligning")
      end
      assert_raises(Pundit::NotAuthorizedError) do
        rate(Operations::Assessments::Align, @manager_context, @fx.pm_only, as_role_id: @fx.pm.role_id)
      end
    end

    should "agree a cell only the started lens role reads" do
      start_alignment(@fx.pm)

      rate(Operations::Assessments::Align, @manager_context, @fx.pm_only, as_role_id: @fx.pm.role_id)
      assert_equal "consistent", rating(@fx.pm_only)&.aligned_frequency
    end
  end

  private

  def start_alignment(role)
    ActsAsTenant.with_tenant(@tenant) do
      Operations::Assessments::StartAlignment.call(
        context: @manager_context, params: { assignment_id: @assignment.id, as_role_id: role.role_id, as_level_ordinal: 2 }
      )
    end
  end

  def rate(operation, context, capability, level_ordinal: 2, frequency: "consistent", **extra)
    ActsAsTenant.with_tenant(@tenant) do
      operation.call(context: context, params: {
        assignment_id: @assignment.id, capability_stable_id: capability.stable_id,
        level_ordinal: level_ordinal, frequency: frequency, **extra
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
