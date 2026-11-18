# frozen_string_literal: true

require "test_helper"

# The line across each team blade: everyone on the role at the team's levels,
# from the latest snapshot, weighted by how many of the team are at each level.
class Assessments::TeamComparisonTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @role_id = SecureRandom.uuid_v7
    @snapshot = LevelComparisonSnapshot.create!(tenant: @tenant, taken_on: Date.new(2026, 11, 1))
    group(2, 6, { "cap-a" => 1.0, "cap-b" => 0.5 })
    group(3, 5, { "cap-a" => 0.4 })
    group(4, 2, { "cap-a" => 2.0 })
  end

  teardown { ActsAsTenant.current_tenant = nil }

  def group(level, size, medians, counts: medians.transform_values { size })
    @snapshot.groups.create!(tenant: @tenant, framework_id: SecureRandom.uuid_v7, role_id: @role_id, level_ordinal: level,
                             group_size: size, capability_medians: medians, capability_counts: counts, category_medians: {})
  end

  def compare(level_counts) = Assessments::TeamComparison.new(tenant: @tenant, role_id: @role_id, level_counts:).call

  should "weight each level's median by how many of the team are at it" do
    result = compare({ 2 => 1, 3 => 3 })

    assert result.shown?
    assert_in_delta 0.55, result.medians["cap-a"], 0.001
    assert_in_delta 0.5, result.medians["cap-b"], 0.001
    assert_equal [ 11, Date.new(2026, 11, 1) ], [ result.group_size, result.taken_on ]
  end

  should "withhold a level's median on a capability fewer than the minimum were scored on" do
    @snapshot.groups.find_by!(level_ordinal: 2).update!(capability_counts: { "cap-a" => 6, "cap-b" => 4 })

    result = compare({ 2 => 1, 3 => 3 })

    assert result.shown?
    assert_nil result.medians["cap-b"]
    assert_in_delta 0.55, result.medians["cap-a"], 0.001
  end

  should "withhold every median of a snapshot taken before counts were kept" do
    @snapshot.groups.each { |g| g.update!(capability_counts: {}) }

    assert_empty compare({ 2 => 1, 3 => 3 }).medians
  end

  should "keep a weighted median just short of met below met" do
    group(5, 6, { "cap-c" => 0.5 })
    group(6, 6, { "cap-c" => 1.0 })

    assert_operator compare({ 5 => 1, 6 => 10_000 }).medians["cap-c"], :<, 1.0
  end

  should "say which levels have too few people, and draw nothing" do
    result = compare({ 2 => 1, 4 => 1 })

    assert_not result.shown?
    assert_equal :too_few, result.reason
    assert_equal [ 4 ], result.short_ordinals
    assert_empty result.medians
  end

  should "read the groups of the tenant it was given, whatever tenant is current" do
    ActsAsTenant.current_tenant = create(:tenant)

    assert compare({ 2 => 1, 3 => 3 }).shown?
  end

  should "read the latest snapshot's day and its groups in one statement" do
    reads = []
    count = ->(*, payload) { reads << payload[:sql] if payload[:sql].include?("level_comparison") }
    result = ActiveSupport::Notifications.subscribed(count, "sql.active_record") { compare({ 2 => 1, 3 => 3 }) }

    assert result.shown?
    assert_equal 1, reads.size, "expected one read, so the day and the groups come from one snapshot"
    assert_match(/level_comparison_snapshots.*level_comparison_groups/m, reads.sole)
  end

  should "take the day from the newest snapshot even when none of its groups are at the levels in view" do
    newer = LevelComparisonSnapshot.create!(tenant: @tenant, taken_on: Date.new(2026, 12, 1))
    newer.groups.create!(tenant: @tenant, framework_id: SecureRandom.uuid_v7, role_id: @role_id, level_ordinal: 5,
                         group_size: 6, capability_medians: { "cap-a" => 1.0 }, capability_counts: { "cap-a" => 6 },
                         category_medians: {})

    result = compare({ 2 => 1 })

    assert_equal [ :too_few, Date.new(2026, 12, 1), [ 2 ] ], [ result.reason, result.taken_on, result.short_ordinals ]
  end

  should "say when there is no snapshot yet" do
    @snapshot.destroy!

    assert_equal :no_snapshot, compare({ 2 => 1 }).reason
  end

  should "say when the tenant has comparisons off" do
    @tenant.comparison_config.enabled = false

    assert_equal :off, compare({ 2 => 1 }).reason
  end
end
