# frozen_string_literal: true

require "test_helper"

class TenantSettings::CommandHandlerTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @admin = ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant)) }
  end

  def handler = TenantSettings::CommandHandler.new(Tenant.find(@tenant.id))
  def config = @tenant.reload.org_graph_config
  def row = TenantRetentionSetting.for(@tenant)
  def stream = Rails.configuration.event_store.read.stream(EventStreamNaming.tenant_settings_stream(tenant: @tenant)).to_a

  # Writes the JSON alone, as a release before the stream could have.
  def previous_release_writes(**settings)
    Tenant.find(@tenant.id).tap { it.org_graph_config.assign_attributes(settings) }.save!
  end

  should "write the period to both places" do
    result = handler.set_retention_period(3, set_by: @admin)

    assert_equal [ 3, false ], [ result.retention_years, result.scheduled_forgetting_stopped ]
    assert_equal [ 3, 3 ], [ config.retention_years, row.retention_years ]
    assert_equal @admin.person_id, stream.last.data[:set_by_id]
    assert_equal @tenant.id, stream.last.metadata[:tenant_id]
  end

  should "turn the schedule on in both places, naming the account in the JSON and the person in the row" do
    assert_equal 2, handler.enable_scheduled_forgetting(enabled_by: @admin) { 2 }

    assert config.scheduled_forgetting
    assert_equal @admin.id, config.scheduled_forgetting_enabled_by_id
    assert_equal [ true, @admin.person_id ], [ row.scheduled_forgetting, row.enabled_by_id ]
    assert_equal config.scheduled_forgetting_enabled_at.to_i, row.enabled_at.to_i
    assert_equal 2, stream.last.data[:confirmed_count]
  end

  should "refuse to turn it on while the period is never, writing nothing" do
    handler.set_retention_period(nil)
    count = stream.count

    assert_raises(TenantSettings::Aggregate::Refused) { handler.enable_scheduled_forgetting { flunk "counted anyway" } }
    assert_not config.scheduled_forgetting
    assert_equal count, stream.count
  end

  should "roll both places back when the block refuses" do
    assert_raises(ArgumentError) { handler.enable_scheduled_forgetting { raise ArgumentError } }

    assert_not config.scheduled_forgetting
    assert_not row.scheduled_forgetting
    assert_empty stream
  end

  should "turn the schedule off in both places, and a shorter period turns it off too" do
    handler.enable_scheduled_forgetting { 0 }
    handler.disable_scheduled_forgetting(disabled_by: @admin)
    assert_equal [ false, false, nil ], [ config.scheduled_forgetting, row.scheduled_forgetting, config.scheduled_forgetting_enabled_by_id ]

    handler.enable_scheduled_forgetting { 0 }
    assert handler.set_retention_period(1).scheduled_forgetting_stopped
    assert_equal [ false, false ], [ config.scheduled_forgetting, row.scheduled_forgetting ]
  end

  should "refuse to turn on a schedule already on, before counting, and keep who turned it on" do
    handler.enable_scheduled_forgetting(enabled_by: @admin) { 0 }
    counted = false

    error = assert_raises(TenantSettings::Aggregate::Refused) { handler.enable_scheduled_forgetting { counted = true } }

    assert_equal "scheduled forgetting is already on", error.message
    assert_not counted
    assert_equal @admin.person_id, row.enabled_by_id
  end

  context "when the JSON disagrees with the stream" do
    should "act on the stream alone, and write the JSON to match it" do
      previous_release_writes(retention_years: 30, scheduled_forgetting: true, scheduled_forgetting_enabled_at: 1.day.ago)
      before = stream.size

      assert_not handler.set_retention_period(2).scheduled_forgetting_stopped

      assert_equal before + 1, stream.size
      assert_equal [ 2, 2 ], [ config.retention_years, row.retention_years ]
      assert_equal [ false, false ], [ config.scheduled_forgetting, row.scheduled_forgetting ]
    end

    should "record nothing when the command is refused" do
      previous_release_writes(retention_years: 3)
      before = stream.size

      assert_raises(TenantSettings::Aggregate::Refused) do
        handler.enable_scheduled_forgetting { raise TenantSettings::Aggregate::Refused, "the count moved" }
      end

      assert_equal before, stream.size
      assert_equal 7, row.retention_years
    end
  end
end
