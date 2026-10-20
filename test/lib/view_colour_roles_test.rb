# frozen_string_literal: true

require "test_helper"
require_relative "kit_colour_roles_test"

# The views outside assessments and frameworks colour themselves with the role
# utilities in theme/ (#546, #547), as Kit does, so a theme reaches them.
class ViewColourRolesTest < ActiveSupport::TestCase
  SOURCES = %w[
    app/views/assessment_cycles/**/*.rb
    app/views/calibration_sessions/**/*.rb
    app/views/evidence/**/*.rb
    app/views/home/**/*.rb
    app/views/settings/**/*.rb
    app/views/tenant/**/*.rb
    app/views/users/**/*.rb
    app/views/notifications/**/*.rb
    app/views/integrations/**/*.rb
    app/views/shared/**/*.rb
    app/views/mcp/**/*.rb
    app/views/oauth/**/*.rb
    app/views/layouts/*.erb
    app/dashboard/**/*.rb
    app/javascript/controllers/person_picker_controller.js
  ].freeze

  # Waiting on a domain token: the evidence valence hues, the vocabulary
  # preview, which copies the hero's per-state panel (#544), and the cycle and
  # calibration data-vis hues (#546). Remove an entry when its site moves; a
  # stale entry fails too.
  PENDING = {
    "app/views/assessment_cycles/attainment/show_view.rb" =>
      %w[bg-green-100 text-green-800 dark:bg-green-900/40 dark:text-green-300
         bg-lime-100 text-lime-800 dark:bg-lime-900/40 dark:text-lime-300
         bg-amber-100 text-amber-800 dark:bg-amber-900/40 dark:text-amber-300
         bg-red-100 text-red-800 dark:bg-red-900/40 dark:text-red-300],
    "app/views/assessment_cycles/cohort/show_view.rb" => %w[bg-blue-500 bg-amber-500 bg-green-500],
    "app/views/calibration_sessions/cohort_drawer_card.rb" =>
      %w[border-violet-500 ring-violet-500 text-violet-700 dark:text-violet-300
         hover:bg-violet-50 dark:hover:bg-violet-900/30],
    "app/views/calibration_sessions/comparison_drawer_chrome.rb" =>
      %w[border-violet-500 bg-violet-500 hover:text-violet-700 dark:hover:text-violet-300],
    "app/views/calibration_sessions/drill_in_view.rb" =>
      %w[border-violet-500 ring-violet-500 text-violet-700 dark:text-violet-300
         hover:bg-violet-50 dark:hover:bg-violet-900/30],
    "app/views/calibration_sessions/divergence_board.rb" => %w[text-white],
    "app/views/calibration_sessions/rater_colours.rb" =>
      %w[bg-teal-600 dark:bg-teal-400 bg-purple-600 dark:bg-purple-400 bg-orange-600 dark:bg-orange-400
         bg-pink-600 dark:bg-pink-400 bg-indigo-600 dark:bg-indigo-400 bg-cyan-600 dark:bg-cyan-400
         border-teal-600 dark:border-teal-400 border-purple-600 dark:border-purple-400
         border-orange-600 dark:border-orange-400 border-pink-600 dark:border-pink-400
         border-indigo-600 dark:border-indigo-400 border-cyan-600 dark:border-cyan-400
         text-gray-950 text-white dark:text-gray-900
         bg-gray-500 dark:bg-gray-400 border-gray-500 dark:border-gray-400],
    "app/views/calibration_sessions/readiness_card.rb" =>
      %w[bg-primary bg-gray-600 dark:bg-gray-300 bg-gray-400 dark:bg-gray-500],
    "app/views/calibration_sessions/show_view.rb" => %w[bg-green-500]
  }.freeze

  should "colour the views with role utilities" do
    offenders = palette_utilities.flat_map do |path, utilities|
      (utilities - PENDING.fetch(path, [])).uniq.map { |utility| "#{path} #{utility}" }
    end

    assert_empty offenders, "Use a role utility from theme/roles.css instead of:\n#{offenders.join("\n")}"
  end

  should "list only pending utilities that are still there" do
    found = palette_utilities
    stale = PENDING.flat_map do |path, utilities|
      (utilities - found.fetch(path, [])).map { |utility| "#{path} #{utility}" }
    end

    assert_empty stale, "Remove from PENDING, it has moved onto a role:\n#{stale.join("\n")}"
  end

  private

  def palette_utilities
    SOURCES.flat_map { |glob| Dir[Rails.root.join(glob)] }.sort.to_h do |path|
      utilities = File.readlines(path).flat_map do |line|
        next [] if line.lstrip.start_with?("#", "//", "<%#")

        line.scan(KitColourRolesTest::PALETTE_UTILITY)
      end
      [ Pathname(path).relative_path_from(Rails.root).to_s, utilities ]
    end
  end
end
