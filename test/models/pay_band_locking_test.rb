# frozen_string_literal: true

require "test_helper"

# Two connections at once, so each must see the other's committed rows.
class PayBandLockingTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @bands = %w[Fixtureland Testonia Mu].map do |location|
      PayBand.new(location:, currency: "AUD", period: "year", minimum: 0, midpoint: 1, maximum: 2).tap { it.match_on }.tap(&:save!)
    end
  end

  teardown do
    ActsAsTenant.current_tenant = nil
    ExchangeRate.where(tenant_id: @tenant.id).delete_all
    PayBand.where(tenant_id: @tenant.id).delete_all
    @tenant.delete
  end

  should "let a reorder leave the tenant free for inserts that reference it" do
    holding(-> { PayBand.reorder!(@bands.reverse.map(&:id)) }) do
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
    ActiveSupport::Notifications.subscribed(record, "sql.active_record") { assert_equal true, PayBand.reorder!(@bands.reverse.map(&:id)) }

    stamped = statements.index { it.start_with?('UPDATE "tenants"') }
    assert_operator stamped, :<, statements.index { it.start_with?("COMMIT") }
    assert_operator stamped, :>, statements.rindex { it.start_with?('UPDATE "pay_bands"') }
  end

  should "leave the tenant's stamp alone when a reorder is refused or stale" do
    before = 1.day.ago.round
    @tenant.update_column(:pay_bands_changed_at, before)
    ids = @bands.map(&:id)

    assert_not PayBand.reorder!(ids.first(2))
    assert_equal :stale, PayBand.reorder!(ids.reverse, from: ids.rotate)
    assert_equal before, @tenant.reload.pay_bands_changed_at
  end

  should "make a second reorder wait for the first and find the order it read has moved" do
    read = @bands.map(&:id)
    second = nil

    holding(-> { PayBand.reorder!(read.reverse, from: read) }) do
      second = Thread.new { on_another_connection { PayBand.reorder!(read.rotate, from: read) } }
      assert_nil second.join(0.5), "the second reorder ran while the first held the list"
    end

    assert_equal :stale, second.value
    assert_equal read.reverse, PayBand.order(:position).pluck(:id)
  end

  should "make a new band wait for a reorder and take a place of its own" do
    added = nil

    holding(-> { PayBand.reorder!(@bands.reverse.map(&:id)) }) do
      added = Thread.new do
        on_another_connection do
          PayBand.new(location: "Lemuria", currency: "AUD", period: "year", minimum: 0, midpoint: 1, maximum: 2).tap { it.match_on }.tap(&:save!)
        end
      end
      assert_nil added.join(0.5), "the band was added while the reorder held the list"
    end

    added.join
    assert_equal [ 1, 2, 3, 4 ], PayBand.order(:position).pluck(:position)
  end

  private

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
    started.pop
    yield
  ensure
    finish << true
    writer&.join
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
        connection.transaction { yield connection }
      end
    end
  end
end
