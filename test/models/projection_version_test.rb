# frozen_string_literal: true

require "test_helper"

class ProjectionVersionTest < ActiveSupport::TestCase
  context "validations" do
    should validate_presence_of(:name)
    should validate_presence_of(:version)
    should validate_numericality_of(:version).only_integer.is_greater_than_or_equal_to(0)
  end

  context ".stamp!" do
    setup do
      stub_const("FakeProjection", Module.new do
        def self.const_missing(name)
          raise NameError, name.to_s
        end
      end)
      FakeProjection.const_set(:PROJECTION_NAME, "fake/projection")
      FakeProjection.const_set(:CODE_VERSION, 3)
    end

    teardown do
      # stub_const writes to Object — clean up so the constant doesn't leak
      # into other tests and create order-dependent pollution.
      Object.send(:remove_const, :FakeProjection) if Object.const_defined?(:FakeProjection)
    end

    should "create a new row when none exists" do
      ProjectionVersion.where(name: "fake/projection").delete_all

      assert_difference "ProjectionVersion.count", 1 do
        ProjectionVersion.stamp!(FakeProjection)
      end

      row = ProjectionVersion.find("fake/projection")
      assert_equal 3, row.version
      assert_not_nil row.applied_at
    end

    should "upsert when row exists" do
      ProjectionVersion.create!(name: "fake/projection", version: 1, applied_at: 1.day.ago)

      assert_no_difference "ProjectionVersion.count" do
        ProjectionVersion.stamp!(FakeProjection)
      end

      assert_equal 3, ProjectionVersion.find("fake/projection").version
    end
  end

  private

  def stub_const(name, value)
    Object.send(:remove_const, name) if Object.const_defined?(name)
    Object.const_set(name, value)
  end

  context ".promote!" do
    should "create a missing stamp and move an existing one forward only" do
      row = ProjectionVersion.promote!("some/projection", 3)
      assert_equal 3, row.version

      assert_equal 5, ProjectionVersion.promote!("some/projection", 5).version
      assert_equal 5, ProjectionVersion.promote!("some/projection", 4).version, "a lower write cannot regress the stamp"
    end

    should "keep applied_at from the write that actually moved the stamp" do
      ProjectionVersion.promote!("some/projection", 5)
      moved_at = ProjectionVersion.find("some/projection").applied_at

      travel 1.hour do
        assert_equal moved_at.to_i, ProjectionVersion.promote!("some/projection", 4).applied_at.to_i
      end
    end

    should "hold the projection's advisory lock while a stamp operation runs" do
      key = ProjectionVersion.lock_key("some/projection")
      # Transactional tests share one connection across threads, so a real
      # second session needs its own PG connection.
      cfg = ActiveRecord::Base.connection_db_config.configuration_hash
      other = PG.connect({ dbname: cfg[:database], user: cfg[:username], password: cfg[:password],
                           host: cfg[:host], port: cfg[:port] }.compact)
      try_lock = lambda do
        got = other.exec("SELECT pg_try_advisory_lock(#{key})").getvalue(0, 0) == "t"
        other.exec("SELECT pg_advisory_unlock(#{key})") if got
        got
      end

      ProjectionVersion.with_operation_lock("some/projection") do
        assert_equal false, try_lock.call, "another session must wait while the operation runs"
      end
      assert_equal true, try_lock.call, "the lock is released afterwards"
    ensure
      other&.close
    end

    should "reject a negative or non-integer version" do
      assert_raises(ArgumentError) { ProjectionVersion.promote!("some/projection", -1) }
      assert_raises(ArgumentError) { ProjectionVersion.promote!("some/projection", "5") }
    end
  end
end
