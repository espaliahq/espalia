# frozen_string_literal: true

require "test_helper"

# The tenant admin's settings for comparing a person with their level.
class Operations::Tenants::UpdateComparisonsTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @tenant = create(:tenant)
    @user = create(:user)
    @tenant_user = ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, user: @user, role: :admin) }
    @context = AuthorizationContext.new(user: @user, tenant_user: @tenant_user, person: nil)
  end

  def call(params, context: @context)
    ActsAsTenant.with_tenant(@tenant) { Operations::Tenants::UpdateComparisons.call(context:, params:) }
  end

  should "start on, comparing groups of 5 or more, with a new snapshot every month" do
    config = @tenant.comparison_config

    assert_equal [ true, 5, 1 ], [ config.enabled, config.min_group_size, config.snapshot_every_months ]
  end

  should "save only the settings given" do
    result = call({ min_group_size: 8 })

    assert_equal({ enabled: true, min_group_size: 8, snapshot_every_months: 1 }, result.slice(:enabled, :min_group_size, :snapshot_every_months))
    assert_equal 8, @tenant.reload.comparison_config.min_group_size
  end

  should "turn comparisons off and take snapshots every 3 or 6 months" do
    call({ enabled: false, snapshot_every_months: 6 })

    config = @tenant.reload.comparison_config
    assert_equal [ false, 6 ], [ config.enabled, config.snapshot_every_months ]
  end

  should "refuse a group smaller than 4, and leave the setting as it was" do
    error = assert_raises(Operations::Base::ParameterError) { call({ min_group_size: 3 }) }

    assert_match(/at least 4/, error.message)
    assert_equal 5, @tenant.reload.comparison_config.min_group_size
  end

  should "refuse a snapshot interval other than 1, 3 or 6 months" do
    assert_raises(Operations::Base::ParameterError) { call({ snapshot_every_months: 2 }) }
    assert_equal 1, @tenant.reload.comparison_config.snapshot_every_months
  end

  should "take the first snapshot when comparisons are turned on" do
    @tenant.update!(comparison_config: ComparisonConfig.new(enabled: false))

    travel_to Time.utc(2026, 11, 18, 9) do
      assert_enqueued_with(job: LevelComparisons::TakeDueSnapshotsJob, args: [ @tenant ]) { call({ enabled: true }) }
      assert_no_enqueued_jobs(only: LevelComparisons::TakeDueSnapshotsJob) { call({ min_group_size: 6 }) }
    end
  end

  should "say when the last snapshot was taken and when the next is due" do
    ActsAsTenant.with_tenant(@tenant) { LevelComparisonSnapshot.create!(tenant: @tenant, taken_on: Date.new(2026, 11, 1)) }

    result = travel_to(Time.utc(2026, 11, 18, 9)) { call({ snapshot_every_months: 3 }) }

    assert_equal [ "2026-11-01", "2027-02-01" ], result.values_at(:last_snapshot_on, :next_snapshot_on)
  end

  should "refuse a member" do
    member = create(:user)
    member_tu = ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, user: member, role: :member) }
    context = AuthorizationContext.new(user: member, tenant_user: member_tu, person: nil)

    assert_raises(Pundit::NotAuthorizedError) { call({ min_group_size: 8 }, context:) }
    assert_equal 5, @tenant.reload.comparison_config.min_group_size
  end
end
