# frozen_string_literal: true

require "test_helper"

class TenantStreams::ReconciliationTest < ActiveSupport::TestCase
  # Holds entries in memory: each record_* call writes to it as an event would.
  class Store
    attr_reader :entries, :log

    def initialize(entries)
      @entries = entries.dup
      @log = []
    end

    def with_aggregate = yield(self)
  end

  # Records additions and removals only, as grants do.
  class AddsAndRemoves < TenantStreams::Reconciliation
    attr_writer :table, :forgotten

    private

    def held_in_table = @table
    def held_in_stream(store) = store.entries
    def forgotten(keys) = keys & Array(@forgotten)
    def record_held(store, key, row) = write(store, :held, key) { store.entries[key] = row }
    def record_removed(store, key, _) = write(store, :removed, key) { store.entries.delete(key) }

    def write(store, kind, key)
      yield
      store.log << [ kind, key ]
    end
  end

  # Also records a row the table changed in place, with what the stream held before.
  class AlsoChanges < AddsAndRemoves
    private

    def changed?(row, recorded) = row != recorded
    def record_changed(store, key, row, recorded) = write(store, :changed, [ key, recorded ]) { store.entries[key] = row }
  end

  setup { @tenant = create(:tenant) }

  def reconciler(klass, store, table:, forgotten: [])
    klass.new(@tenant, repository: store).tap do
      it.table = table
      it.forgotten = forgotten
    end
  end

  context "a reconciler that records changes" do
    should "record an entry the table changed in place, with what the stream held, and nothing on a second run" do
      store = Store.new("a" => 1, "b" => 2, "gone" => 3)
      reconcile = reconciler(AlsoChanges, store, table: { "a" => 1, "b" => 5, "new" => 4 })

      report = reconcile.call

      assert_equal [ 1, 1, 1, 3 ], [ report.added, report.removed, report.changed, report.recorded ]
      assert_equal({ "a" => 1, "b" => 5, "new" => 4 }, store.entries)
      assert_equal [ [ :held, "new" ], [ :removed, "gone" ], [ :changed, [ "b", 2 ] ] ], store.log
      assert_equal 0, reconcile.call.recorded
    end

    should "leave alone a forgotten row that differs" do
      store = Store.new("a" => 1, "b" => 2)
      report = reconciler(AlsoChanges, store, table: { "a" => 0, "b" => 0 }, forgotten: [ "a" ]).call

      assert_equal 1, report.changed
      assert_equal [ [ :changed, [ "b", 2 ] ] ], store.log
    end
  end

  context "a reconciler that says nothing about changes" do
    should "count an entry held on both sides as equal, however it differs" do
      store = Store.new("a" => 1)
      report = reconciler(AddsAndRemoves, store, table: { "a" => 9 }).call

      assert_equal 0, report.changed
      assert_equal({ "a" => 1 }, store.entries)
      assert_empty store.log
    end
  end
end
