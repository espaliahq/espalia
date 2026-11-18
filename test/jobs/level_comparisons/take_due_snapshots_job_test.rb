# frozen_string_literal: true

require "test_helper"

# Snapshots are taken on the 1st of the month, every 1, 3 or 6 months, in
# each tenant's own time zone; the first as soon as comparisons are on.
class LevelComparisons::TakeDueSnapshotsJobTest < ActiveJob::TestCase
  def snapshot_days(tenant) = ActsAsTenant.with_tenant(tenant) { LevelComparisonSnapshot.order(:taken_on).pluck(:taken_on) }

  def snapshotted(on:, **config)
    tenant = create(:tenant, comparison_config: ComparisonConfig.new(**config))
    ActsAsTenant.with_tenant(tenant) { LevelComparisonSnapshot.create!(tenant:, taken_on: on) } if on
    tenant
  end

  def run_at(time) = travel_to(time) { LevelComparisons::TakeDueSnapshotsJob.perform_now }

  should "take a tenant's first snapshot straight away" do
    tenant = snapshotted(on: nil)

    run_at Time.utc(2026, 11, 18, 9)

    assert_equal [ Date.new(2026, 11, 18) ], snapshot_days(tenant)
  end

  should "take the next on the 1st of the following month, not before" do
    tenant = snapshotted(on: Date.new(2026, 11, 18))

    run_at Time.utc(2026, 11, 30, 23)
    assert_equal 1, snapshot_days(tenant).size

    run_at Time.utc(2026, 12, 1, 0, 5)
    assert_equal [ Date.new(2026, 11, 18), Date.new(2026, 12, 1) ], snapshot_days(tenant)

    run_at Time.utc(2026, 12, 1, 1, 5)
    assert_equal 2, snapshot_days(tenant).size, "expected one snapshot a day"
  end

  should "wait 3 or 6 months when the tenant takes them less often" do
    quarterly = snapshotted(on: Date.new(2026, 11, 1), snapshot_every_months: 3)
    half_yearly = snapshotted(on: Date.new(2026, 11, 1), snapshot_every_months: 6)

    run_at Time.utc(2027, 1, 1, 9)
    run_at Time.utc(2027, 2, 1, 9)

    assert_equal [ Date.new(2026, 11, 1), Date.new(2027, 2, 1) ], snapshot_days(quarterly)
    assert_equal [ Date.new(2026, 11, 1) ], snapshot_days(half_yearly)
  end

  should "go by the tenant's own calendar" do
    sydney = snapshotted(on: Date.new(2026, 11, 1))
    sydney.update!(time_zone: "Australia/Sydney")
    utc = snapshotted(on: Date.new(2026, 11, 1))

    run_at Time.utc(2026, 11, 30, 14)

    assert_equal Date.new(2026, 12, 1), snapshot_days(sydney).last
    assert_equal [ Date.new(2026, 11, 1) ], snapshot_days(utc)
  end

  should "take none while comparisons are off" do
    tenant = snapshotted(on: nil, enabled: false)

    run_at Time.utc(2026, 12, 1, 9)

    assert_empty snapshot_days(tenant)
  end

  should "keep going past a tenant whose snapshot fails" do
    failing = snapshotted(on: nil)
    kept = snapshotted(on: nil)
    real = LevelComparisonSnapshot.method(:take!)
    fake = ->(tenant:, on:) { tenant == failing ? raise("unreachable") : real.call(tenant:, on:) }

    LevelComparisonSnapshot.stub(:take!, fake) { run_at Time.utc(2026, 11, 18, 9) }

    assert_empty snapshot_days(failing)
    assert_equal 1, snapshot_days(kept).size
  end
end
