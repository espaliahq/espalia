# frozen_string_literal: true

require "test_helper"
require_relative "../support/rebuild_lock"

class RebuildLockTest < ActiveSupport::TestCase
  include RebuildLock

  # A lock still held when the connection closes is freed only once the backend
  # exits, so the next test could find it taken (#223).
  should "release the rebuild's locks before closing its connection" do
    locks_at_close = []
    count_locks = ->(conn) { locks_at_close << advisory_locks_held_by(conn.backend_pid) }
    spy = Module.new do
      define_method(:close) do
        count_locks.call(self)
        super()
      end
    end
    connect = PG.method(:connect)

    PG.stub(:connect, ->(*args) { connect.call(*args).tap { it.singleton_class.prepend(spy) } }) do
      while_rebuilding(create(:tenant), OrgGraph::Projections::Members) { }
    end

    assert_equal [ 0 ], locks_at_close
  end

  private

  def advisory_locks_held_by(pid)
    ActiveRecord::Base.connection.select_value(
      "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND granted AND pid = #{Integer(pid)}"
    )
  end
end
