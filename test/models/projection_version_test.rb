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
end
