# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/projection_replay"

class TenantSettings::Projections::RetentionTest < ActiveSupport::TestCase
  include ProjectionReplayHelpers

  PROJECTION = TenantSettings::Projections::Retention

  setup do
    @tenant = create(:tenant)
    @handler = TenantSettings::CommandHandler.new(@tenant)
  end

  def row = TenantRetentionSetting.unscoped.find_by(tenant_id: @tenant.id)

  should "hold no row until a setting is recorded, and read as the defaults" do
    assert_nil row
    assert_equal [ 7, false ], TenantRetentionSetting.for(@tenant).values_at(:retention_years, :scheduled_forgetting)
  end

  should "rebuild the same row, with the same id, from the stream" do
    @handler.set_retention_period(4)
    @handler.enable_scheduled_forgetting { 0 }
    before = snapshot_read_models(PROJECTION, @tenant)

    PROJECTION.reset!(tenant: @tenant)
    assert_equal before, snapshot_read_models(PROJECTION, @tenant), "the reset alone writes where the stream ends"
    Projections::Replayer.replay(projection_class: PROJECTION, tenant: @tenant)

    assert_equal before, snapshot_read_models(PROJECTION, @tenant)
    assert_equal [ 4, true ], [ row.retention_years, row.scheduled_forgetting ]
  end

  should "remove a row the stream doesn't hold" do
    ActsAsTenant.with_tenant(@tenant) { TenantRetentionSetting.create!(tenant: @tenant, retention_years: 1, scheduled_forgetting: true) }

    PROJECTION.reset!(tenant: @tenant)

    assert_nil row
  end
end
