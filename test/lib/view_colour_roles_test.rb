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

  # Waiting on a component variant or a domain token. Remove an entry when its
  # site moves; a stale entry fails too.
  PENDING = {}.freeze

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
      utilities = File.readlines(path).flat_map do |line|
        next [] if line.lstrip.start_with?("#", "//", "<%#")

        line.scan(KitColourRolesTest::PALETTE_UTILITY)
      end
      [ relative, utilities ]
    end.to_h
  end
end
