# frozen_string_literal: true

require "test_helper"

# The brand colour fails AA as text (#302), so readable brand text uses
# `text-primary-ink`, at full strength. `text-primary` stays legal only on a
# checkbox or radio, where the forms plugin paints the checked mark from it.
class BrandTextClassesTest < ActiveSupport::TestCase
  RAW_PRIMARY_TEXT = %r{(?<![\w-])(?:[a-z-]+:)*text-primary(?![\w-])}
  FADED_INK = %r{(?<![\w-])(?:[a-z-]+:)*text-primary-ink/\d+}
  SECONDARY_TEXT = /(?<![\w-])(?:[a-z-]+:)*text-secondary(?![\w-])/
  INPUT_CONTEXT = /\binput\(|type: "(checkbox|radio)"/
  CONTEXT_LINES = 5

  def offenders(pattern, allow_inputs: false)
    Dir[Rails.root.join("app/**/*.{rb,js,erb}")].flat_map do |path|
      lines = File.readlines(path)
      lines.each_with_index.filter_map do |line, i|
        next unless line.match?(pattern)
        next if allow_inputs && lines[[ i - CONTEXT_LINES, 0 ].max..i].join.match?(INPUT_CONTEXT)

        "#{Pathname(path).relative_path_from(Rails.root)}:#{i + 1}"
      end
    end
  end

  should "use text-primary-ink for every readable use of the brand colour" do
    found = offenders(RAW_PRIMARY_TEXT, allow_inputs: true)
    assert_empty found, "Readable brand text must use text-primary-ink (docs/guidelines/phlex-views.md):\n#{found.join("\n")}"
  end

  should "never fade the brand ink, which is what puts it above AA" do
    found = offenders(FADED_INK)
    assert_empty found, "Faded brand ink drops below AA:\n#{found.join("\n")}"
  end

  should "not use the secondary brand colour as text (3.8:1 on white)" do
    found = offenders(SECONDARY_TEXT)
    assert_empty found, "text-secondary fails AA as text:\n#{found.join("\n")}"
  end
end
