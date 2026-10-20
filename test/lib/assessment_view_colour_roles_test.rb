# frozen_string_literal: true

require "test_helper"
require_relative "kit_colour_roles_test"

# The assessment views colour themselves with the role and domain utilities
# in theme/ (#544), as Kit does, so a theme reaches them.
class AssessmentViewColourRolesTest < ActiveSupport::TestCase
  SOURCES = "app/views/assessments/**/*.rb"

  PENDING = {}.freeze

  should "colour the assessment views with role utilities" do
    offenders = palette_utilities.flat_map do |path, utilities|
      (utilities.map(&:first) - PENDING.fetch(path, [])).uniq.map { |utility| "#{path} #{utility}" }
    end

    assert_empty offenders, "Use a role utility from theme/roles.css instead of:\n#{offenders.join("\n")}"
  end

  should "list only pending utilities that are still there" do
    found = palette_utilities.transform_values { |utilities| utilities.map(&:first) }
    stale = PENDING.flat_map do |path, utilities|
      (utilities - found.fetch(path, [])).map { |utility| "#{path} #{utility}" }
    end

    assert_empty stale, "Remove from PENDING, it has moved onto a role:\n#{stale.join("\n")}"
  end

  private

  def palette_utilities
    Dir[Rails.root.join(SOURCES)].sort.to_h do |path|
      relative = Pathname(path).relative_path_from(Rails.root).to_s
      utilities = File.readlines(path).each_with_index.flat_map do |line, i|
        next [] if line.lstrip.start_with?("#")

        line.scan(KitColourRolesTest::PALETTE_UTILITY).map { |utility| [ utility, i + 1 ] }
      end
      [ relative, utilities ]
    end
  end
end
