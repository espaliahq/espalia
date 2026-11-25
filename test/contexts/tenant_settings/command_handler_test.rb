# frozen_string_literal: true

require "test_helper"

class TenantSettings::CommandHandlerTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @admin = ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant)) }
  end

  def handler = TenantSettings::CommandHandler.new(Tenant.find(@tenant.id))
  def row = TenantRetentionSetting.for(@tenant)
  def stream = Rails.configuration.event_store.read.stream(EventStreamNaming.tenant_settings_stream(tenant: @tenant)).to_a
  def stored_config = JSON.parse(Tenant.where(id: @tenant.id).pick(Arel.sql("org_graph_config::text")))

  # Writes the retired keys, as the previous release does while a deploy is in flight.
  def previous_release_writes(**settings)
    Tenant.where(id: @tenant.id).update_all([ "org_graph_config = org_graph_config || ?::jsonb", settings.to_json ])
  end

  should "write the period to the stream" do
    result = handler.set_retention_period(3, set_by: @admin)

    assert_equal [ 3, false ], [ result.retention_years, result.scheduled_forgetting_stopped ]
    assert_equal 3, row.retention_years
    assert_equal @admin.person_id, stream.last.data[:set_by_id]
    assert_equal @tenant.id, stream.last.metadata[:tenant_id]
  end

  should "turn the schedule on, naming the admin's person" do
    assert_equal 2, handler.enable_scheduled_forgetting(enabled_by: @admin) { 2 }

    assert_equal [ true, @admin.person_id ], [ row.scheduled_forgetting, row.enabled_by_id ]
    assert_not_nil row.enabled_at
    assert_equal 2, stream.last.data[:confirmed_count]
  end

  should "refuse to turn it on while the period is never, writing nothing" do
    handler.set_retention_period(nil)
    count = stream.count

    assert_raises(TenantSettings::Aggregate::Refused) { handler.enable_scheduled_forgetting { flunk "counted anyway" } }
    assert_not row.scheduled_forgetting
    assert_equal count, stream.count
  end

  should "roll back when the block refuses" do
    assert_raises(ArgumentError) { handler.enable_scheduled_forgetting { raise ArgumentError } }

    assert_not row.scheduled_forgetting
    assert_empty stream
  end

  should "turn the schedule off, and a shorter period turns it off too" do
    handler.enable_scheduled_forgetting { 0 }
    handler.disable_scheduled_forgetting(disabled_by: @admin)
    assert_equal [ false, nil ], [ row.scheduled_forgetting, row.enabled_by_id ]

    handler.enable_scheduled_forgetting { 0 }
    assert handler.set_retention_period(1).scheduled_forgetting_stopped
    assert_not row.scheduled_forgetting
  end

  should "refuse to turn on a schedule already on, before counting, and keep who turned it on" do
    handler.enable_scheduled_forgetting(enabled_by: @admin) { 0 }
    counted = false

    error = assert_raises(TenantSettings::Aggregate::Refused) { handler.enable_scheduled_forgetting { counted = true } }

    assert_equal "scheduled forgetting is already on", error.message
    assert_not counted
    assert_equal @admin.person_id, row.enabled_by_id
  end

  context "when the previous release has written the retired keys" do
    setup { previous_release_writes(staleness_days: 30, retention_years: 30, scheduled_forgetting: true, scheduled_forgetting_enabled_at: 1.day.ago) }

    should "act on the stream alone, and remove the keys, keeping the tenant's other settings" do
      before = stream.size

      assert_not handler.set_retention_period(2).scheduled_forgetting_stopped

      assert_equal before + 1, stream.size
      assert_equal [ 2, false ], [ row.retention_years, row.scheduled_forgetting ]
      assert_equal({ "staleness_days" => 30 }, stored_config)
    end

    should "remove them with each command" do
      handler.enable_scheduled_forgetting { 0 }
      assert_equal({ "staleness_days" => 30 }, stored_config)

      previous_release_writes(scheduled_forgetting: false)
      handler.disable_scheduled_forgetting
      assert_equal({ "staleness_days" => 30 }, stored_config)
    end

    should "leave them and record nothing when the command is refused" do
      before = stream.size

      assert_raises(TenantSettings::Aggregate::Refused) do
        handler.enable_scheduled_forgetting { raise TenantSettings::Aggregate::Refused, "the count moved" }
      end

      assert_equal before, stream.size
      assert_equal 7, row.retention_years
      assert_equal 30, stored_config["retention_years"]
    end
  end
end
