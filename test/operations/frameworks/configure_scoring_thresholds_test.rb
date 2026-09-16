# frozen_string_literal: true

require "test_helper"

# ConfigureScoringThresholds is a full-replacement settings write: every
# call sets the whole configuration, omitted thresholds revert to system
# defaults (nil columns), out-of-range values classify as invalid params
# before they can overflow the decimal(5,2) projection write, and the gate
# is tenant-admin (update_settings?).
class Operations::Frameworks::ConfigureScoringThresholdsTest < ActiveSupport::TestCase
  setup do
    @admin_user = create(:user)
    @member_user = create(:user)
    @tenant = create(:tenant)

    ActsAsTenant.with_tenant(@tenant) do
      @admin_tu = create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      @member_tu = create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)

      @framework_id = SecureRandom.uuid_v7
      Frameworks::CommandHandler.new.create_framework(@framework_id, "Eng")
    end

    @admin_ctx = AuthorizationContext.new(user: @admin_user, tenant_user: @admin_tu, person: nil)
    @member_ctx = AuthorizationContext.new(user: @member_user, tenant_user: @member_tu, person: nil)
  end

  def configure(ctx, params)
    Operations::Frameworks::ConfigureScoringThresholds.call(context: ctx, params: params)
  end

  def framework
    FrameworkState::Framework.find_by!(framework_id: @framework_id)
  end

  context "as a tenant admin" do
    should "store the configured thresholds on the read model" do
      ActsAsTenant.with_tenant(@tenant) do
        result = configure(@admin_ctx, {
          framework_id: @framework_id,
          mastery_threshold: 1.2,
          meeting_expectation_threshold: 0.9,
          underperforming_threshold: 0.7,
          overperformance_cap: 2,
          deficit_threshold: 1.5
        })

        assert_equal 1.2, result[:mastery_threshold]
        assert_equal 0.9, framework.meeting_expectation_threshold.to_f
        assert_equal 0.7, framework.underperforming_threshold.to_f
        assert_equal 2, framework.overperformance_cap
        assert_equal 1.5, framework.deficit_threshold.to_f
      end
    end

    should "revert an omitted threshold to the system default (full replacement)" do
      ActsAsTenant.with_tenant(@tenant) do
        configure(@admin_ctx, { framework_id: @framework_id, mastery_threshold: 1.3 })
        assert_equal 1.3, framework.mastery_threshold.to_f

        result = configure(@admin_ctx, { framework_id: @framework_id, deficit_threshold: 2.0 })

        assert_nil result[:mastery_threshold]
        assert_nil framework.mastery_threshold
        assert_equal 2.0, framework.deficit_threshold.to_f
      end
    end

    should "revert an omitted cap to its default and an omitted deficit to nil (system default)" do
      ActsAsTenant.with_tenant(@tenant) do
        configure(@admin_ctx, {
          framework_id: @framework_id, overperformance_cap: 3, deficit_threshold: 2.5
        })

        # A follow-up call omitting both reverts them: the cap column is NOT
        # NULL so the default value itself is written; the tolerance stores
        # nil, so the engine's default applies and can move with the code.
        result = configure(@admin_ctx, { framework_id: @framework_id })

        assert_equal PersonDevelopment::Scoring::DEFAULT_OVERPERFORMANCE_CAP,
                     result[:overperformance_cap]
        assert_nil result[:deficit_threshold]
        assert_nil framework.deficit_threshold
        assert_equal PersonDevelopment::Scoring::DEFAULT_DEFICIT_THRESHOLD,
                     framework.scoring_thresholds[:deficit_threshold] ||
                       PersonDevelopment::Scoring::DEFAULT_DEFICIT_THRESHOLD
      end
    end

    should "reject a threshold that would overflow the decimal column" do
      ActsAsTenant.with_tenant(@tenant) do
        error = assert_raises(Operations::Base::ParameterError) do
          configure(@admin_ctx, { framework_id: @framework_id, mastery_threshold: 1000 })
        end
        assert_match(/mastery_threshold must be between/, error.message)
      end
    end

    should "reject a negative threshold and an out-of-range cap" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Operations::Base::ParameterError) do
          configure(@admin_ctx, { framework_id: @framework_id, underperforming_threshold: -0.5 })
        end
        assert_raises(Operations::Base::ParameterError) do
          configure(@admin_ctx, { framework_id: @framework_id, overperformance_cap: 101 })
        end
      end
    end

    should "reject a non-numeric threshold" do
      ActsAsTenant.with_tenant(@tenant) do
        error = assert_raises(Operations::Base::ParameterError) do
          configure(@admin_ctx, { framework_id: @framework_id, mastery_threshold: "high" })
        end
        assert_match(/mastery_threshold must be a Numeric/, error.message)
      end
    end
  end

  context "threshold ordering" do
    should "reject thresholds that are not ordered underperforming < meeting < mastery" do
      ActsAsTenant.with_tenant(@tenant) do
        error = assert_raises(Operations::Base::ParameterError) do
          configure(@admin_ctx, { framework_id: @framework_id,
                                  mastery_threshold: 0.9, meeting_expectation_threshold: 0.95 })
        end
        assert_match(/ordered underperforming < meeting_expectation < mastery/, error.message)
      end
    end

    should "check the order against the defaults an omitted threshold falls back to" do
      # underperforming omitted → 0.80; a meeting threshold below it is inverted.
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Operations::Base::ParameterError) do
          configure(@admin_ctx, { framework_id: @framework_id, meeting_expectation_threshold: 0.7 })
        end
      end
    end
  end

  context "as a plain tenant member" do
    should "be denied" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Pundit::NotAuthorizedError) do
          configure(@member_ctx, { framework_id: @framework_id, mastery_threshold: 1.2 })
        end
      end
    end
  end
end
