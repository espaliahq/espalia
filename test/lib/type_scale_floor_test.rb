# frozen_string_literal: true

require "test_helper"

# 10px is the smallest deliberate type in the app (#336); 9px badges fell
# below any legibility floor.
class TypeScaleFloorTest < ActiveSupport::TestCase
  ARBITRARY_SIZE = /text-\[(\d*\.?\d+)(px|rem|em)\]/
  FLOOR_PX = 10
  ROOT_PX = 16

  should "not size any text below 10px" do
    offenders = Dir[Rails.root.join("app/**/*.{rb,js,erb}")].flat_map do |path|
      File.readlines(path).each_with_index.flat_map do |line, i|
        line.scan(ARBITRARY_SIZE).filter_map do |value, unit|
          px = unit == "px" ? value.to_f : value.to_f * ROOT_PX
          "#{Pathname(path).relative_path_from(Rails.root)}:#{i + 1} (#{value}#{unit})" if px < FLOOR_PX
        end
      end
    end

    assert_empty offenders, "Text below #{FLOOR_PX}px:\n#{offenders.join("\n")}"
  end
end
