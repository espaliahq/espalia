# frozen_string_literal: true

require "test_helper"

# The comparison tab's numbers for an agent: the person's scores beside the
# group's medians, under the same minimum and snapshot as the web.
class Operations::Assessments::LevelComparisonTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @fx = build_role_lens_framework(tenant: @tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @user = create(:user)
      @person = create(:person, tenant: @tenant, email: @user.email)
      @tenant_user = create(:tenant_user, tenant: @tenant, user: @user, person: @person, role: :member)
      @snapshot = LevelComparisonSnapshot.create!(tenant: @tenant, taken_on: Date.new(2026, 11, 1))
      [ [ 1, 6 ], [ 2, 5 ], [ 3, 2 ] ].each do |level, size|
        @snapshot.groups.create!(tenant: @tenant, framework_id: @fx.framework_id, role_id: @fx.engineer.role_id,
                                 level_ordinal: level, group_size: size,
                                 capability_medians: { @fx.shared.stable_id => 0.5, @fx.e_only.stable_id => 1.0 },
                                 category_medians: { @fx.shared.category_id => 0.75 })
      end
    end
    @assignment, = enrol_in_role_lens_framework(@person, @fx, tenant: @tenant, level_ordinal: 2)
    @context = AuthorizationContext.new(user: @user, tenant_user: @tenant_user, person: @person)
  end

  def call(params = {}, context: @context)
    ActsAsTenant.with_tenant(@tenant) do
      Operations::Assessments::LevelComparison.call(context:, params: { assignment_id: @assignment.id }.merge(params))
    end
  end

  should "compare with the person's own level, naming the snapshot and the levels on offer" do
    result = call

    assert_equal [ true, "2026-11-01", 5 ], result.values_at(:enabled, :taken_on, :min_group_size)
    assert_equal({ ordinal: 2, code: "E2", group_size: 5 }, result[:level])
    assert_equal [ [ "E1", 6, true ], [ "E2", 5, true ], [ "E3", nil, false ] ],
                 result[:levels].map { |l| l.values_at(:code, :group_size, :available) }
  end

  should "give each capability's group median beside the person's, as a percentage" do
    rows = call[:capabilities].to_h { |c| [ c[:stable_id], c.slice(:name, :group_median) ] }

    assert_equal({ name: "Critical Thinking", group_median: 50 }, rows[@fx.shared.stable_id])
    assert_equal({ name: "Systems Design", group_median: 100 }, rows[@fx.e_only.stable_id])
    assert_equal [ 75 ], call[:categories].map { |c| c[:group_median] }
    assert call[:capabilities].all? { |c| c.key?(:your_score) && c.key?(:scored) }
  end

  should "say what the numbers mean at the level compared with, and why a score is missing" do
    result = call({ level_ordinal: 1 })

    assert_equal [ "percent_of_assessed_level_expectations", "E1", "E2" ],
                 result[:scale].values_at(:unit, :assessed_level, :next_level)
    shared = result[:capabilities].find { |c| c[:stable_id] == @fx.shared.stable_id }
    assert_equal [ false, nil, "not_rated_at_assessed_level" ], shared.values_at(:scored, :your_score, :unscored_reason)
    category = result[:categories].first
    assert_equal [ false, nil ], category.values_at(:scored, :your_score)
    assert category[:unscored_reason], "expected the category to say why it has no score"
  end

  # A level below their own counts as rated only where they rated it, as on a lens.
  should "read the person's scores at the level compared with" do
    ActsAsTenant.with_tenant(@tenant) do
      cycle_id = AssessmentCycleEnrollment.find_by!(person_id: @person.id).cycle_id
      [ 1, 2 ].each do |level|
        PersonDevelopment::CommandHandler.new.rate_self(@person.id, @fx.framework_id, @fx.shared.stable_id,
                                                        level_ordinal: level, frequency: "consistent", cycle_id:)
      end
    end
    shared = ->(result) { result[:capabilities].find { |c| c[:stable_id] == @fx.shared.stable_id } }

    assert_equal 100, shared.(call)[:your_score], "E2 met, on E2's scale"
    at_e1 = call({ level_ordinal: 1 })
    assert_equal({ ordinal: 1, code: "E1", group_size: 6 }, at_e1[:level])
    assert_equal 200, shared.(at_e1)[:your_score], "E1 met and E2 in full, on E1's scale"
  end

  should "keep the person's score on a capability the snapshot has no median for" do
    ActsAsTenant.with_tenant(@tenant) do
      @snapshot.groups.find_by!(level_ordinal: 2).update!(capability_medians: { @fx.shared.stable_id => 0.5 })
      cycle_id = AssessmentCycleEnrollment.find_by!(person_id: @person.id).cycle_id
      PersonDevelopment::CommandHandler.new.rate_self(@person.id, @fx.framework_id, @fx.e_only.stable_id,
                                                      level_ordinal: 2, frequency: "consistent", cycle_id:)
    end

    added = call[:capabilities].find { |c| c[:stable_id] == @fx.e_only.stable_id }

    assert_equal [ 100, nil ], added&.values_at(:your_score, :group_median)
  end

  should "send no group scores for a level under the minimum" do
    result = call({ level_ordinal: 3 })

    assert_nil result[:level][:group_size]
    assert_empty result[:capabilities]
    assert_empty result[:categories]
  end

  should "refuse a level that isn't the person's or one either side" do
    @tenant.update!(comparison_config: ComparisonConfig.new)
    error = assert_raises(Operations::Base::ParameterError) { call({ level_ordinal: 7 }) }

    assert_match(/E1, E2 or E3/, error.message)
  end

  should "say so when comparisons are off" do
    @tenant.update!(comparison_config: ComparisonConfig.new(enabled: false))

    assert_equal({ enabled: false }, call)
  end

  should "refuse someone who can't see the assessment" do
    other = create(:user)
    other_tu = ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, user: other, role: :member) }

    assert_raises(Pundit::NotAuthorizedError) do
      call(context: AuthorizationContext.new(user: other, tenant_user: other_tu, person: nil))
    end
  end
end
