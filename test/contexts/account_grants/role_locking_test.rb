# frozen_string_literal: true

require "test_helper"

# A role change or a link, and a forget, on two connections, so each must see the other's committed rows.
class AccountGrants::RoleLockingTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @tenant = create(:tenant)
    as_tenant do
      @ada = account(:admin)
      @bo = account(:admin)
      @cy = create(:tenant_user, tenant: @tenant, person: nil)
      @dee = create(:person, tenant: @tenant)
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
    users = [ @ada, @bo, @cy ].compact.map(&:user_id)
    TenantUser.unscoped.where(tenant_id: @tenant.id).delete_all
    User.where(id: users).delete_all
    Person.unscoped.where(tenant_id: @tenant.id).delete_all
    TenantSettingChange.unscoped.where(tenant_id: @tenant.id).delete_all
    @tenant.delete
  end

  should "make a forget wait while a role change holds the accounts it counted" do
    forget = nil
    as_tenant { @cy.update_columns(role: "admin") }

    holding(-> { AccountGrants::CommandHandler.new.set_role(@ada, :member) }) do
      pids = Queue.new
      forget = Thread.new { on_another_connection { |connection| pids << backend_pid(connection); erase(@bo) } }
      assert_waiting(pids, forget)
    end

    forget.join
    assert_equal "member", role_of(@ada)
    assert TenantUser.unscoped.find(@bo.id).forgotten_at, "the forget goes ahead once the change commits"
  end

  should "refuse a forget that waited for a demotion and now holds the last admin" do
    forget = nil

    holding(-> { AccountGrants::CommandHandler.new.set_role(@ada, :member) }) do
      pids = Queue.new
      forget = Thread.new do
        on_another_connection { |connection| pids << backend_pid(connection); erase(@bo) }
        nil
      rescue AccountGrants::Aggregate::LastAdmin => error
        error
      end
      assert_waiting(pids, forget)
    end

    assert_instance_of AccountGrants::Aggregate::LastAdmin, forget.value
    assert_equal "member", role_of(@ada)
    assert_nil TenantUser.unscoped.find(@bo.id).forgotten_at
    assert_not Person.unscoped.find(@bo.person_id).forgotten?, "the refusal rolls the erase back"
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

  should "make a forget wait while a link holds the grants lock, then unlink the person it linked" do
    forget = nil

    holding(-> { TenantUser.find(@cy.id).link_to!(@dee, match: :admin) }) do
      pids = Queue.new
      forget = Thread.new { on_another_connection { |connection| pids << backend_pid(connection); erase_person(@dee.id) } }
      assert_waiting(pids, forget)
    end

    forget.join
    cy = TenantUser.unscoped.find(@cy.id)
    assert_nil cy.person_id
    assert cy.forgotten_at, "the forget erases the account linked while it waited"
  end

  should "make a link wait while a forget holds the grants lock, then refuse the forgotten person" do
    refused = nil

    holding(-> { erase_person(@dee.id) }) do
      pids = Queue.new
      refused = Thread.new do
        on_another_connection do |connection|
          pids << backend_pid(connection)
          TenantUser.find(@cy.id).link_to!(@dee, match: :admin)
          nil
        rescue AccountGrants::Aggregate::PersonForgotten => error
          error
        end
      end
      assert_waiting(pids, refused)
    end

    assert_instance_of AccountGrants::Aggregate::PersonForgotten, refused.value
    assert_nil TenantUser.unscoped.find(@cy.id).person_id
  end

  should "make a link wait for a forget holding the person's row, without taking the grants lock first" do
    locked = Queue.new
    go = Queue.new
    forget = Thread.new do
      on_another_connection do
        Person.lock.find(@dee.id)
        locked << true
        go.pop
        erase_person(@dee.id)
      end
    end
    flunk "the forget never locked the person" unless locked.pop(timeout: 10)

    pids = Queue.new
    refused = Thread.new do
      on_another_connection do |connection|
        pids << backend_pid(connection)
        TenantUser.find(@cy.id).link_to!(@dee, match: :admin)
        nil
      rescue AccountGrants::Aggregate::PersonForgotten => error
        error
      end
    end
    assert_waiting(pids, refused)
    go << true

    assert forget.join(15), "the forget finished"
    assert_instance_of AccountGrants::Aggregate::PersonForgotten, refused.value
    assert_nil TenantUser.unscoped.find(@cy.id).person_id
  ensure
    go << true
    [ forget, refused ].compact.each { it.join(15) || it.kill }
  end

  private

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def account(role) = create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant), role:)

  def role_of(account) = TenantUser.unscoped.find(account.id).role

  # The writes OrgGraph::Forgetting#erase_identifiers makes: the person's row,
  # then the grants lock, then their accounts.
  def erase(account) = erase_person(account.person_id)

  def erase_person(person_id)
    now = Time.current
    Person.where(id: person_id).update_all(name: Person::FORMER_MEMBER, email: nil, external_id: nil, forgotten_at: now)
    ids = AccountGrants::CommandHandler.new.unlink_forgotten(person_id)
    TenantUser.where(id: ids).update_all(user_id: nil, slack_user_id: nil, forgotten_at: now, updated_at: now)
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
