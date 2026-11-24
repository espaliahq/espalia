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

  # The previous release, still serving during a deploy, writes the JSON alone.
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

  context "after the previous release wrote the JSON alone" do
    should "record what it wrote before acting, so a shorter period still turns the schedule off" do
      previous_release_writes(scheduled_forgetting: true, scheduled_forgetting_enabled_at: 1.day.ago,
                              scheduled_forgetting_enabled_by_id: @admin.id)

      assert handler.set_retention_period(2).scheduled_forgetting_stopped

      held = stream.find { it.is_a?(TenantSettings::Events::ScheduledForgettingEnabled) }
      assert held.data[:already_held]
      assert_equal @admin.person_id, held.data[:enabled_by_id]
      assert_equal [ false, false ], [ config.scheduled_forgetting, row.scheduled_forgetting ]
    end

    should "count under the period it wrote, not the one the stream held" do
      previous_release_writes(retention_years: 30)

      handler.enable_scheduled_forgetting { |settings| assert_equal 30, settings.retention_years; 0 }
      assert_equal 30, row.retention_years
    end

    should "keep what it recorded when the command is refused, so the next dry run counts by it" do
      previous_release_writes(retention_years: 3)

      assert_raises(ArgumentError) { handler.enable_scheduled_forgetting { raise ArgumentError, "the count moved" } }

      assert_equal 3, row.retention_years
      assert_equal 3, TenantRetentionSetting.longer_period(Tenant.find(@tenant.id))
      assert_not row.scheduled_forgetting
    end

    should "record what it wrote as the system, while the command itself names the admin" do
      previous_release_writes(retention_years: 3)

      AuditMetadata.with(acting_via: :web, actor_id: @admin.person_id, correlation_id: "request-1") do
        AuditMetadata.wrap_event_store { handler.set_retention_period(5, set_by: @admin) }
      end

      held, set = stream.last(2)
      assert_equal [ 3, true ], [ held.data[:retention_years], held.data[:already_held] ]
      assert_equal [ "system", nil, "request-1" ], held.metadata.to_h.values_at(:acting_via, :actor_id, :correlation_id)
      assert_equal [ "web", @admin.person_id ], set.metadata.to_h.values_at(:acting_via, :actor_id)
    end

    should "keep the time and account it recorded when the schedule stays on" do
      at = 2.days.ago.round
      previous_release_writes(scheduled_forgetting: true, scheduled_forgetting_enabled_at: at, scheduled_forgetting_enabled_by_id: @admin.id)

      handler.set_retention_period(10)

      assert_equal [ at, @admin.id ], [ config.scheduled_forgetting_enabled_at, config.scheduled_forgetting_enabled_by_id ]
      assert_equal at, row.enabled_at
    end

    should "turn the schedule off that it turned off" do
      handler.enable_scheduled_forgetting { 0 }
      previous_release_writes(scheduled_forgetting: false, scheduled_forgetting_enabled_at: nil, scheduled_forgetting_enabled_by_id: nil)

      handler.set_retention_period(10)

      assert_not row.scheduled_forgetting
    end
  end
end
