# frozen_string_literal: true

require "test_helper"
require_relative "kit_colour_roles_test"

# The assessment views colour themselves with the role and domain utilities
# in theme/ (#544), as Kit does, so a theme reaches them.
class AssessmentViewColourRolesTest < ActiveSupport::TestCase
  SOURCES = "app/views/assessments/**/*.rb"

  # Waiting on a component variant or a domain token that doesn't exist yet: the lens
  # and exploration hue, the hero's per-state panel, the inset panel (Kit::Card :inset,
  # #563), status micro-tags (Kit::Badge, #563) and the assumed-consistent level chip.
  # Remove an entry when its site moves; a stale entry fails too.
  PENDING = {
    "app/views/assessments/capability_card.rb" =>
      %w[bg-sky-50 dark:bg-sky-900/30 text-sky-800 dark:text-sky-200 ring-sky-200 dark:ring-sky-800],
    "app/views/assessments/category_chip_bar.rb" =>
      %w[text-white/80 dark:text-gray-900/80 text-white/70 dark:text-gray-900/70 text-gray-600 dark:text-gray-300],
    "app/views/assessments/exploration_chips.rb" =>
      %w[bg-sky-50 text-sky-800 ring-sky-200 dark:bg-sky-900/30 dark:text-sky-200 dark:ring-sky-800],
    "app/views/assessments/hero_summary.rb" =>
      %w[border-red-300 dark:border-red-700 border-amber-300 dark:border-amber-700 border-blue-300
         dark:border-blue-700 text-blue-700 dark:text-blue-300 border-green-300 dark:border-green-700
         border-purple-300 dark:border-purple-700 text-purple-700 dark:text-purple-300
         bg-gray-50/50 dark:bg-gray-800/30],
    "app/views/assessments/index_view.rb" =>
      %w[border-sky-200 dark:border-sky-800 hover:border-sky-400 dark:hover:border-sky-600],
    "app/views/assessments/lens_alignment_chips.rb" =>
      %w[text-green-800 ring-green-200 dark:text-green-200 dark:ring-green-800
         text-amber-800 ring-amber-200 dark:text-amber-200 dark:ring-amber-800],
    "app/views/assessments/lens_control.rb" =>
      %w[bg-sky-100 dark:bg-sky-900/40 text-sky-800 dark:text-sky-200 ring-sky-300 dark:ring-sky-700],
    "app/views/assessments/level_chip.rb" =>
      %w[bg-blue-300 dark:bg-blue-700 text-blue-900 dark:text-blue-100],
    "app/views/assessments/score_explainer_modal.rb" =>
      %w[bg-gray-50/50 dark:bg-gray-800/30]
  }.freeze

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
