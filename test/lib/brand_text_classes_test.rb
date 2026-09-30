# frozen_string_literal: true

require "test_helper"

# The brand colour fails AA as text (#302), so readable brand text uses
# `text-primary-ink`. `text-primary` stays legal only on a checkbox or radio,
# where the forms plugin paints the checked mark from it.
class BrandTextClassesTest < ActiveSupport::TestCase
  RAW_PRIMARY_TEXT = %r{(?<![\w-])(?:[a-z-]+:)*text-primary(?![\w/-])}
  INPUT_CONTEXT = /\binput\(|type: "(checkbox|radio)"/
  CONTEXT_LINES = 5

  should "use text-primary-ink for every readable use of the brand colour" do
    offenders = Dir[Rails.root.join("app/**/*.{rb,js}")].flat_map do |path|
      lines = File.readlines(path)
      lines.each_with_index.filter_map do |line, i|
        next unless line.match?(RAW_PRIMARY_TEXT)
        next if lines[[ i - CONTEXT_LINES, 0 ].max..i].join.match?(INPUT_CONTEXT)

        "#{Pathname(path).relative_path_from(Rails.root)}:#{i + 1}"
      end
    end

    assert_empty offenders, "Readable brand text must use text-primary-ink (docs/guidelines/phlex-views.md):\n#{offenders.join("\n")}"
  end
end
