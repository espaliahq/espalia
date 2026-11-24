# frozen_string_literal: true

require "test_helper"

# A role change and a forget on two connections, so each must see the other's committed rows.
class AccountGrants::RoleLockingTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @tenant = create(:tenant)
    as_tenant do
      @ada = account(:admin)
      @bo = account(:admin)
    end
  end

  teardown do
    connection = ActiveRecord::Base.connection
    ids = connection.quote("tenant-#{@tenant.id}/%")
    connection.execute(<<~SQL)
      WITH linked AS (SELECT event_id FROM event_store_events_in_streams WHERE stream LIKE #{ids}),
           unlinked AS (DELETE FROM event_store_events_in_streams WHERE event_id IN (SELECT event_id FROM linked))
      DELETE FROM event_store_events WHERE event_id IN (SELECT event_id FROM linked)
    SQL
    users = [ @ada, @bo ].compact.map(&:user_id)
    TenantUser.unscoped.where(tenant_id: @tenant.id).delete_all
    User.where(id: users).delete_all
    Person.unscoped.where(tenant_id: @tenant.id).delete_all
    @tenant.delete
  end

  should "make a forget wait while a role change holds the accounts it counted" do
    forget = nil

    holding(-> { AccountGrants::CommandHandler.new.set_role(@ada, :member) }) do
      pids = Queue.new
      forget = Thread.new { on_another_connection { |connection| pids << backend_pid(connection); erase(@bo) } }
      assert_waiting(pids, forget)
    end

    forget.join
    assert_equal "member", role_of(@ada)
    assert TenantUser.unscoped.find(@bo.id).forgotten_at, "the forget goes ahead once the change commits"
  end

  should "not count an admin a forget took first, and refuse to demote the last one" do
    refused = nil

    holding(-> { erase(@bo) }) do
      pids = Queue.new
      refused = Thread.new do
        on_another_connection do |connection|
          pids << backend_pid(connection)
          AccountGrants::CommandHandler.new.set_role(@ada, :member)
          nil
        rescue AccountGrants::Aggregate::LastAdmin => error
          error
        end
      end
      assert_waiting(pids, refused)
    end

    assert_equal "the organisation must keep an admin", refused.value&.message
    assert_equal "admin", role_of(@ada)
  end

  private

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def account(role) = create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant), role:)

  def role_of(account) = TenantUser.unscoped.find(account.id).role

  # The write OrgGraph::Forgetting#erase_identifiers makes to the person's accounts.
  def erase(account)
    TenantUser.where(person_id: account.person_id)
      .update_all(person_id: nil, user_id: nil, slack_user_id: nil, forgotten_at: Time.current, updated_at: Time.current)
  end

  def backend_pid(connection) = connection.select_value("SELECT pg_backend_pid()")

  # Runs the write in a transaction on its own connection and holds it open
  # while the block runs, then commits.
  def holding(write)
    started = Queue.new
    finish = Queue.new
    writer = Thread.new do
      on_another_connection do
        write.call
      ensure
        started << true
        finish.pop
      end
    end
    unless started.pop(timeout: 10)
      writer.join unless writer.alive?
      flunk "the writer never started its transaction"
    end
    yield
  ensure
    finish << true
    if writer && !writer.join(15)
      writer.kill
      flunk "the writer never committed" unless $!
    end
  end

  # Polls until the worker's backend waits on a lock, so the test proves
  # contention rather than a worker that simply hadn't started.
  def assert_waiting(pids, worker, within: 10)
    pid = pids.pop(timeout: within) or flunk "the worker never reported its connection"
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + within
    waiting = TenantUser.sanitize_sql_array([ "SELECT 1 FROM pg_locks WHERE pid = ? AND NOT granted", pid ])
    until TenantUser.uncached { TenantUser.connection.select_value(waiting) }
      flunk "the worker finished without waiting" unless worker.alive?
      flunk "the worker never waited for a lock" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.02
    end
  end

  def on_another_connection
    ActiveRecord::Base.connection_pool.with_connection do |connection|
      as_tenant do
        connection.transaction do
          # No worker waits on a lock for ever, so a stuck test fails rather than hangs.
          connection.execute("SET LOCAL lock_timeout = '15s'")
          yield connection
        end
      end
    end
  end
end
