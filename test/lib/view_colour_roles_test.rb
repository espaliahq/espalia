# frozen_string_literal: true

require "test_helper"
require_relative "kit_colour_roles_test"

# The views colour themselves with the role and domain utilities in theme/
# (#544–#547), as Kit does, so a theme reaches them.
class ViewColourRolesTest < ActiveSupport::TestCase
  SOURCES = %w[
    app/views/assessments/**/*.rb
    app/views/frameworks/**/*.rb
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

  # Waiting on a component variant or a domain token: the lens and exploration
  # hue, the hero's per-state panel, the evidence valence hues, the cycle and
  # calibration data-vis hues, the matrix surfaces the .mx-* classes share, and
  # the suggestion and search marks. Remove an entry when its site moves; a
  # stale entry fails too.
  PENDING = {
    "app/views/frameworks/explorer/concerns/pending_archive.rb" => %w[[&>td]:decoration-red-400],
    "app/views/frameworks/explorer/concerns/search_highlight.rb" =>
      %w[bg-amber-200 text-amber-950 dark:bg-amber-400/40 dark:text-amber-50],
    "app/views/frameworks/explorer/concerns/suggestion_decoration.rb" =>
      %w[decoration-amber-400 decoration-red-400 decoration-sky-400 text-sky-700 dark:text-sky-300
         bg-gray-100 dark:bg-gray-800 hover:bg-gray-200 dark:hover:bg-gray-700],
    "app/views/frameworks/explorer/illustration_frame.rb" => %w[bg-gray-300 dark:bg-gray-600],
    "app/views/frameworks/explorer/matrix_category_group.rb" =>
      %w[bg-gray-100 dark:bg-gray-800 hover:bg-gray-200 dark:hover:bg-gray-700],
    "app/views/frameworks/explorer/matrix_cell.rb" => %w[bg-gray-50/40 dark:bg-gray-800/20 text-gray-300 dark:text-gray-600],
    "app/views/frameworks/explorer/matrix_header.rb" => %w[bg-gray-50 dark:bg-gray-900],
    "app/views/frameworks/explorer/matrix_row.rb" => %w[group-hover:bg-gray-50 bg-amber-100 dark:bg-amber-900/30],
    "app/views/frameworks/explorer/pending_count_badge.rb" =>
      %w[bg-amber-100 dark:bg-amber-900/40 text-amber-800 dark:text-amber-200],
    "app/views/frameworks/explorer/pending_illustration_frame.rb" => %w[bg-amber-400],
    "app/views/frameworks/publication_review_view.rb" => %w[border-amber-300 dark:border-amber-700],
    # The role pane toggle's open state is set in framework_explorer_controller.js,
    "app/views/frameworks/show_view.rb" => %w[bg-gray-100 dark:bg-gray-800 hover:bg-gray-200 dark:hover:bg-gray-700],
    "app/views/frameworks/suggestions/inline_indicator.rb" => %w[bg-amber-100 dark:bg-amber-900/30],
    "app/views/frameworks/suggestions/show_view.rb" => %w[bg-gray-50 dark:bg-gray-800/50]
  }.freeze

  # Moving onto roles in another pane
  IN_PROGRESS = %w[
    app/views/frameworks/explorer/role_tree.rb
    app/views/frameworks/explorer/field_editor_template.rb
  ].freeze

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
    SOURCES.flat_map { |glob| Dir[Rails.root.join(glob)] }.sort.filter_map do |path|
      relative = Pathname(path).relative_path_from(Rails.root).to_s
      next if IN_PROGRESS.include?(relative)

      utilities = File.readlines(path).flat_map do |line|
        next [] if line.lstrip.start_with?("#", "//", "<%#")

        line.scan(KitColourRolesTest::PALETTE_UTILITY)
      end
      [ relative, utilities ]
    end.to_h
  end
end
