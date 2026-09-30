# frozen_string_literal: true

require "test_helper"

# 10px is the smallest deliberate type in the app (#336); 9px badges fell
# below any legibility floor.
class TypeScaleFloorTest < ActiveSupport::TestCase
  SUB_FLOOR_SIZE = /text-\[(?:[0-9](?:\.\d+)?px|0?\.[0-5]\d*rem)\]/

  should "not size any text below 10px" do
    offenders = Dir[Rails.root.join("app/**/*.{rb,js,erb}")].flat_map do |path|
      File.readlines(path).each_with_index.filter_map do |line, i|
        "#{Pathname(path).relative_path_from(Rails.root)}:#{i + 1}" if line.match?(SUB_FLOOR_SIZE)
      end
    end

    assert_empty offenders, "Text below 10px:\n#{offenders.join("\n")}"
  end
end
