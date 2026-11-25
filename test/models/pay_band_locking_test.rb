# frozen_string_literal: true

require "test_helper"

# Two connections at once, so each must see the other's committed rows.
class PayBandLockingTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @bands = %w[Fixtureland Testonia Mu].map do |location|
      any_band(location)
    end
  end

  teardown do
    ActsAsTenant.current_tenant = nil
    ExchangeRate.where(tenant_id: @tenant.id).delete_all
    PayBand.where(tenant_id: @tenant.id).delete_all
    linked = PayBand.sanitize_sql_array([ "stream LIKE ?", "tenant-#{@tenant.id}/%" ])
    event_ids = PayBand.connection.select_values("SELECT event_id FROM event_store_events_in_streams WHERE #{linked}")
    PayBand.connection.execute("DELETE FROM event_store_events_in_streams WHERE #{linked}")
    PayBand.connection.execute(PayBand.sanitize_sql_array([ "DELETE FROM event_store_events WHERE event_id IN (?)", event_ids ])) if event_ids.any?
    @tenant.delete
  end

  should "let a reorder leave the tenant free for inserts that reference it" do
    holding(-> { reorder_pay_bands!(@bands.reverse.map(&:id)) }) do
      inserted = Thread.new do
        insert_rate
      rescue ActiveRecord::LockWaitTimeout
        :blocked
      end

      assert_equal :inserted, inserted.value
    end
  end

  should "stamp the tenant in the same transaction as the new order" do
    statements = []
    record = ->(*, payload) { statements << payload[:sql] }
    ActiveSupport::Notifications.subscribed(record, "sql.active_record") { reorder_pay_bands!(@bands.reverse.map(&:id)) }

    stamped = statements.index { it.start_with?('UPDATE "tenants"') }
    assert_operator stamped, :<, statements.index { it.start_with?("COMMIT") }
    assert_operator stamped, :>, statements.rindex { it.start_with?('UPDATE "pay_bands"') }
  end

  should "leave the tenant's stamp alone when a reorder is refused or stale" do
    before = 1.day.ago.round
    @tenant.update_column(:pay_bands_changed_at, before)
    ids = @bands.map(&:id)

    assert_raises(TenantPlanningInputs::Refused) { reorder_pay_bands!(ids.first(2)) }
    stale = assert_raises(TenantPlanningInputs::Refused) { reorder_pay_bands!(ids.reverse, from: ids.rotate) }
    assert_match "has changed since you read it", stale.message
    assert_equal before, @tenant.reload.pay_bands_changed_at
  end

  should "make a second reorder wait for the first and find the order it read has moved" do
    read = @bands.map(&:id)
    second = nil

    holding(-> { reorder_pay_bands!(read.reverse, from: read) }) do
      pids = Queue.new
      second = Thread.new do
        on_another_connection do |connection|
          pids << connection.select_value("SELECT pg_backend_pid()")
          reorder_pay_bands!(read.rotate, from: read)
        rescue TenantPlanningInputs::Refused => e
          e.message
        end
      end
      assert_waiting_for_list(pids, second)
    end

    assert_match "has changed since you read it", second.value
    assert_equal read.reverse, PayBand.order(:position).pluck(:id)
  end

  should "make a new band wait for a reorder and take a place of its own" do
    added = nil

    holding(-> { reorder_pay_bands!(@bands.reverse.map(&:id)) }) do
      pids = Queue.new
      added = Thread.new do
        on_another_connection do |connection|
          pids << connection.select_value("SELECT pg_backend_pid()")
          any_band("Lemuria")
        end
      end
      assert_waiting_for_list(pids, added)
    end

    added.join
    assert_equal [ 1, 2, 3, 4 ], PayBand.order(:position).pluck(:position)
  end

  # The release a4 replaces takes the list lock and then the stream lock; a4
  # takes the stream lock alone, so the two can serve side by side.
  context "a command beside the previous release" do
    should "not wait for a holder of the list lock alone" do
      holding(-> { take_lock(list_lock_key) }) do
        added = Thread.new do
          on_another_connection do |connection|
            connection.execute("SET LOCAL lock_timeout = '2s'")
            any_band("Lemuria")
          end
        rescue ActiveRecord::LockWaitTimeout
          :blocked
        end

        assert_kind_of PayBand, added.value
      end
    end

    should "wait for a holder of both locks and finish once it commits" do
      added = nil

      holding(-> { take_lock(list_lock_key) && take_lock(stream_lock_key) }) do
        pids = Queue.new
        added = Thread.new do
          on_another_connection do |connection|
            pids << connection.select_value("SELECT pg_backend_pid()")
            any_band("Lemuria")
          end
        end
        assert_waiting_for_list(pids, added)
      end

      assert_kind_of PayBand, added.value
      assert_equal 4, PayBand.count
    end
  end

  private

  def list_lock_key = "pay_bands:#{@tenant.id}"

  def stream_lock_key = TenantPlanningInputs::Repository.new.send(:lock_key, @tenant)

  def take_lock(key)
    PayBand.connection.execute(PayBand.sanitize_sql_array([ "SELECT pg_advisory_xact_lock(hashtextextended(?, 0))", key ]))
  end

  def any_band(location)
    save_planning_input!(:pay_bands, PayBand.new(location:, currency: "AUD", period: "year", minimum: 0, midpoint: 1, maximum: 2).tap { it.match_on })
  end

  # Runs the write in a transaction on its own connection and holds it open
  # while the block runs, then commits.
  def holding(write)
    started = Queue.new
    finish = Queue.new
    writer = Thread.new do
      on_another_connection do
        PayBand.transaction do
          write.call
        ensure
          started << true
          finish.pop
        end
      end
    end
    unless started.pop(timeout: 5)
      writer.join unless writer.alive?
      flunk "the writer never started its transaction"
    end
    yield
  ensure
    finish << true
    if writer && !writer.join(10)
      writer.kill
      # Leave an earlier failure as the one reported.
      flunk "the writer never committed" unless $!
    end
  end

  # Polls until the worker's backend waits on an advisory lock, so the test
  # proves contention rather than a worker that simply hadn't started.
  def assert_waiting_for_list(pids, worker, within: 5)
    pid = pids.pop(timeout: within) or flunk "the worker never reported its connection"
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + within
    waiting = PayBand.sanitize_sql_array([ "SELECT 1 FROM pg_locks WHERE pid = ? AND locktype = 'advisory' AND NOT granted", pid ])
    # Uncached, or the query cache answers every poll with the first one's miss.
    until PayBand.uncached { PayBand.connection.select_value(waiting) }
      flunk "the worker finished while the list was held" unless worker.alive?
      flunk "the worker never waited for the list: #{activity(pid)}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.02
    end
  end

  def activity(pid)
    PayBand.connection.select_one(PayBand.sanitize_sql_array([ <<~SQL, pid ])).inspect
      SELECT state, wait_event_type, wait_event, left(query, 200) AS query,
             (SELECT string_agg(locktype || ':' || mode, ', ') FROM pg_locks WHERE pid = a.pid AND NOT granted) AS waiting_on
      FROM pg_stat_activity a WHERE pid = ?
    SQL
  end

  def insert_rate
    on_another_connection do |connection|
      connection.execute("SET LOCAL lock_timeout = '2s'")
      connection.execute(ExchangeRate.sanitize_sql_array([ <<~SQL, SecureRandom.uuid_v7, @tenant.id ]))
        INSERT INTO exchange_rates (id, tenant_id, from_currency, to_currency, rate, applies_from, created_at, updated_at)
        VALUES (?, ?, 'AUD', 'NZD', 1.1, CURRENT_DATE, now(), now())
      SQL
      :inserted
    end
  end

  def on_another_connection
    ActiveRecord::Base.connection_pool.with_connection do |connection|
      ActsAsTenant.with_tenant(@tenant) do
        connection.transaction do
          # No worker waits on a lock for ever, so a stuck test fails rather than hangs.
          connection.execute("SET LOCAL lock_timeout = '10s'")
          yield connection
        end
      end
    end
  end
end
