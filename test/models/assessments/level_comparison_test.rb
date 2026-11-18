# frozen_string_literal: true

require "test_helper"

# What a person's comparison with their level can show: their level and one
# either side, each with its group's size once it meets the tenant's minimum,
# and the group's middle scores only then.
class Assessments::LevelComparisonTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @fx = build_role_lens_framework(tenant: @tenant)
    @person = create(:person, tenant: @tenant)
    @assignment, = enrol_in_role_lens_framework(@person, @fx, tenant: @tenant, level_ordinal: 2)
    @snapshot = LevelComparisonSnapshot.create!(tenant: @tenant, taken_on: Date.new(2026, 11, 1))
  end

  teardown { ActsAsTenant.current_tenant = nil }

  def group(level, size, medians = { @fx.shared.stable_id => 1.0 })
    @snapshot.groups.create!(tenant: @tenant, framework_id: @fx.framework_id, role_id: @fx.engineer.role_id,
                             level_ordinal: level, group_size: size, capability_medians: medians,
                             category_medians: { @fx.shared.category_id => 1.0 })
  end

  def comparison(as_level: nil)
    Assessments::LevelComparison.new(lens: Assessments::Lens.resolve(assignment: @assignment, as_level:), tenant: @tenant)
  end

  should "offer the person's level and one either side, sized once a group meets the minimum" do
    group(1, 7)
    group(2, 3)

    levels = comparison.levels.map { |l| [ l.code, l.own, l.group_size, l.available ] }

    assert_equal [ [ "E1", false, 7, true ], [ "E2", true, nil, false ], [ "E3", false, nil, false ] ], levels
    assert_equal 2, comparison.own_ordinal
  end

  should "give a group's middle scores only when it meets the minimum" do
    group(1, 7, { @fx.shared.stable_id => 0.75 })
    group(2, 4)

    assert_equal({ @fx.shared.stable_id => 0.75 }, comparison.group_at(1).capability_medians)
    assert_nil comparison.group_at(2)
    assert_nil comparison.group_at(3)
  end

  should "follow the minimum the tenant sets" do
    group(2, 4)
    @tenant.update!(comparison_config: ComparisonConfig.new(min_group_size: 4))

    assert comparison.group_at(2)
    assert_equal 4, comparison.min_group_size
  end

  should "suggest the nearest level that has enough people when the person's own has too few" do
    group(1, 6)
    group(3, 9)

    assert_equal 1, comparison.suggested_ordinal
  end

  should "stop at the ends of the ladder" do
    assert_equal %w[E2 E3], comparison(as_level: 3).levels.map(&:code)
  end

  should "say which snapshot it reads, and nothing when there is none or comparisons are off" do
    assert_equal Date.new(2026, 11, 1), comparison.taken_on
    assert comparison.enabled?

    @tenant.update!(comparison_config: ComparisonConfig.new(enabled: false))
    assert_not comparison.enabled?

    @snapshot.destroy!
    assert_nil comparison.taken_on
    assert comparison.levels.none?(&:available)
  end
end
