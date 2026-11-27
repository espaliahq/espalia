# frozen_string_literal: true

require "test_helper"

class ComparisonConfigTest < ActiveSupport::TestCase
  context ".floor_for" do
    should "keep a size an admin may set" do
      assert_equal 4, ComparisonConfig.floor_for(4)
      assert_equal 12, ComparisonConfig.floor_for("12")
    end

    should "never fall below the smallest size an admin may set" do
      [ nil, "", "five", "0", 0, -3, 3, "4.5", "012x" ].each do |size|
        assert_equal ComparisonConfig::LOWEST_MIN_GROUP_SIZE, ComparisonConfig.floor_for(size), "for #{size.inspect}"
      end
    end

    should "read a string in base ten" do
      assert_equal 10, ComparisonConfig.floor_for("010")
    end
  end
end
