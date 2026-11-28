# frozen_string_literal: true

require "test_helper"

# Two connections at once, so each must see the other's committed rows.
class OrgGraph::ForgettingLockingTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @tenant = create(:tenant)
    TenantSettings::CommandHandler.new(@tenant).enable_scheduled_forgetting { 0 }
  end

  teardown do
    next unless @tenant

    stream = EventStreamNaming.tenant_settings_stream(tenant: @tenant)
    ids = Tenant.sanitize_sql_array([ "SELECT event_id FROM event_store_events_in_streams WHERE stream = ?", stream ])
    Tenant.connection.execute("DELETE FROM event_store_events_in_streams WHERE event_id IN (#{ids})")
    Tenant.connection.execute("DELETE FROM event_store_events WHERE event_id NOT IN (SELECT event_id FROM event_store_events_in_streams)")
    TenantRetentionSetting.unscoped.where(tenant_id: @tenant.id).delete_all
    TenantSettingChange.unscoped.where(tenant_id: @tenant.id).delete_all
    @tenant.delete
  end

  should "make a disable wait for an erase that read the schedule as on" do
    holding_erase_locks do
      assert TenantRetentionSetting.scheduled?(@tenant)
      assert_equal :blocked, disable
    end
    assert_equal :committed, disable
  end

  should "let an erase see a disable committed first" do
    assert_equal :committed, disable

    holding_erase_locks { assert_not TenantRetentionSetting.scheduled?(@tenant) }
  end

  private

  # Takes the locks an erase takes, as an erase does, and holds them while
  # the block runs.
  def holding_erase_locks
    ActsAsTenant.with_tenant(@tenant) do
      Tenant.transaction do
        OrgGraph::Forgetting.new(@tenant).send(:lock_settings)
        yield
      end
    end
  end

  def disable
    disables { TenantSettings::CommandHandler.new(Tenant.find(@tenant.id)).disable_scheduled_forgetting }
  end

  # Runs the write on its own connection, giving up on any lock after a second.
  def disables
    Thread.new do
      on_another_connection do |connection|
        connection.execute("SET LOCAL lock_timeout = '1s'")
        yield
        :committed
      end
    rescue ActiveRecord::LockWaitTimeout
      :blocked
    end.value
  end

  def on_another_connection
    ActiveRecord::Base.connection_pool.with_connection do |connection|
      ActsAsTenant.with_tenant(@tenant) do
        connection.transaction do
          connection.execute("SET LOCAL lock_timeout = '10s'")
          yield connection
        end
      end
    end
  end
end
