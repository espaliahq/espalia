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
    group(2, 6, "cap-a" => 1.0, "cap-b" => 0.5)
    group(3, 5, "cap-a" => 0.4)
    group(4, 2, "cap-a" => 2.0)
  end

  teardown { ActsAsTenant.current_tenant = nil }

  def group(level, size, medians)
    @snapshot.groups.create!(tenant: @tenant, framework_id: SecureRandom.uuid_v7, role_id: @role_id, level_ordinal: level,
                             group_size: size, capability_medians: medians, category_medians: {})
  end

  def compare(level_counts) = Assessments::TeamComparison.new(tenant: @tenant, role_id: @role_id, level_counts:).call

  should "weight each level's median by how many of the team are at it" do
    result = compare({ 2 => 1, 3 => 3 })

    assert result.shown?
    assert_in_delta 0.55, result.medians["cap-a"], 0.001
    assert_in_delta 0.5, result.medians["cap-b"], 0.001
    assert_equal [ 11, Date.new(2026, 11, 1) ], [ result.group_size, result.taken_on ]
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

  should "read the day's snapshot with its groups when it is replaced between reads" do
    stale = @snapshot
    @snapshot = LevelComparisonSnapshot.new(tenant: @tenant, taken_on: stale.taken_on)
    stale.groups.each { |g| @snapshot.groups.build(g.attributes.except("id", "snapshot_id", "created_at", "updated_at")) }
    stale.destroy!
    @snapshot.save!

    LevelComparisonSnapshot.stub(:latest, stale) { assert compare({ 2 => 1, 3 => 3 }).shown? }
  end

  should "take the day and the groups from one snapshot when a newer one lands between reads" do
    newer = lambda do
      LevelComparisonSnapshot.create!(tenant: @tenant, taken_on: Date.new(2026, 12, 1)).tap do |snapshot|
        snapshot.groups.create!(tenant: @tenant, framework_id: SecureRandom.uuid_v7, role_id: @role_id, level_ordinal: 5,
                                group_size: 6, capability_medians: { "cap-a" => 1.0 }, category_medians: {})
      end
    end
    result = LevelComparisonSnapshot.stub(:latest, newer) { compare({ 5 => 1 }) }

    assert_equal [ :too_few, Date.new(2026, 11, 1) ], [ result.reason, result.taken_on ]
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
