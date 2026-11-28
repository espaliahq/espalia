# frozen_string_literal: true

require "test_helper"

# A Google sign-in and a forget on two connections, so each must see the other's committed rows.
class UserGoogleProvisioningLockingTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  EMAIL = "frankie@example.com"

  setup do
    @tenant = create(:tenant)
    @person = ActsAsTenant.with_tenant(@tenant) { create(:person, tenant: @tenant, email: EMAIL) }
  end

  teardown do
    next unless @tenant

    connection = ActiveRecord::Base.connection
    tenants = [ @tenant, @other ].compact
    tenants.each do |tenant|
      ids = connection.quote("tenant-#{tenant.id}/%")
      connection.execute(<<~SQL)
        WITH linked AS (SELECT event_id FROM event_store_events_in_streams WHERE stream LIKE #{ids}),
             unlinked AS (DELETE FROM event_store_events_in_streams WHERE event_id IN (SELECT event_id FROM linked))
        DELETE FROM event_store_events WHERE event_id IN (SELECT event_id FROM linked)
      SQL
    end
    tenant_ids = tenants.map(&:id)
    users = TenantUser.unscoped.where(tenant_id: tenant_ids).pluck(:user_id) + User.where(email: EMAIL).pluck(:id)
    TenantUser.unscoped.where(tenant_id: tenant_ids).delete_all
    User.where(id: users).delete_all
    Person.unscoped.where(tenant_id: tenant_ids).delete_all
    tenants.each(&:delete)
  end

  should "refuse a sign-in that waited on a forget, leaving no account, membership or event" do
    signing_in = nil

    forgetting do
      pids = Queue.new
      signing_in = Thread.new { on_another_connection { |connection| pids << backend_pid(connection); User.from_google_omniauth(auth) } }
      assert_waiting(pids, signing_in)
    end

    assert_equal [ nil, :no_matching_account ], signing_in.value
    assert_not User.exists?(email: EMAIL), "no account is left for the address"
    assert_empty TenantUser.unscoped.where(tenant_id: @tenant.id)
    assert_empty grants_events, "the account's grants event rolls back with it"
    assert Person.unscoped.find(@person.id).forgotten?
  end

  should "provision into the next tenant whose person matches when the first is forgotten meanwhile" do
    @other = create(:tenant)
    later = travel(1.minute) { ActsAsTenant.with_tenant(@other) { create(:person, tenant: @other, email: EMAIL) } }
    signing_in = nil

    forgetting do
      pids = Queue.new
      signing_in = Thread.new { on_another_connection { |connection| pids << backend_pid(connection); User.from_google_omniauth(auth) } }
      assert_waiting(pids, signing_in)
    end

    user, reason = signing_in.value
    assert_nil reason
    assert_empty TenantUser.unscoped.where(tenant_id: @tenant.id), "nothing is left in the forgotten person's tenant"
    assert_equal later.id, TenantUser.unscoped.find_by!(user_id: user.id, tenant_id: @other.id).person_id
  end

  private

  def auth
    OmniAuth::AuthHash.new(provider: "google_oauth2", uid: "uid-frankie",
                           info: { email: EMAIL, email_verified: true }, extra: { raw_info: { email_verified: true } })
  end

  # The writes of the forget that a sign-in can wait on: the person's row
  # locked and erased, then the grants lock. Held open while the block runs,
  # then committed.
  def forgetting
    started = Queue.new
    finish = Queue.new
    forget = Thread.new do
      on_another_connection do |connection|
        connection.transaction do
          ActsAsTenant.with_tenant(@tenant) do
            Person.lock.find(@person.id)
            Person.where(id: @person.id).update_all(name: Person::FORMER_MEMBER, email: nil, forgotten_at: Time.current)
            AccountGrants::CommandHandler.new.unlink_forgotten(@person.id)
          end
        ensure
          started << true
          finish.pop
        end
      end
    end
    flunk "the forget never started" unless started.pop(timeout: 10)
    yield
  ensure
    finish << true
    forget&.join(15) || forget&.kill
  end

  def grants_events
    store = Rails.configuration.event_store
    [ EventStreamNaming.tenant_account_grants_stream(tenant: @tenant), EventStreamNaming.account_grants_stream(tenant: @tenant) ]
      .flat_map { store.read.stream(it).to_a }
  end

  def backend_pid(connection) = connection.select_value("SELECT pg_backend_pid()")

  # Polls until the worker's backend waits on a lock, so the test proves
  # contention rather than a worker that simply hadn't started.
  def assert_waiting(pids, worker, within: 10)
    pid = pids.pop(timeout: within) or flunk "the worker never reported its connection"
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + within
    waiting = User.sanitize_sql_array([ "SELECT 1 FROM pg_locks WHERE pid = ? AND NOT granted", pid ])
    until User.uncached { User.connection.select_value(waiting) }
      flunk "the worker finished without waiting" unless worker.alive?
      flunk "the worker never waited for a lock" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.02
    end
  end

  def on_another_connection
    ActiveRecord::Base.connection_pool.with_connection do |connection|
      # No worker waits on a lock for ever, so a stuck test fails rather than hangs.
      connection.execute("SET lock_timeout = '15s'")
      yield connection
    ensure
      connection.execute("RESET lock_timeout")
    end
  end
end
