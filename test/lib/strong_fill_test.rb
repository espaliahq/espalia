# frozen_string_literal: true

require "test_helper"

# A strong fill carries text only in the pairing a Kit component owns (#560), so
# `bg-*-strong` and `bg-tone-strong` appear only inside app/components/kit.
class StrongFillTest < ActiveSupport::TestCase
  STRONG_FILL = /(?<![\w-])(?:[^\s"'`:]+:)*!?bg-[a-z-]*strong(?:-hover)?(?![\w-])/

  SOURCES = %w[
    app/views/**/*.rb
    app/components/shell/**/*.rb
    app/components/shared/**/*.rb
    app/dashboard/**/*.rb
    app/helpers/**/*.rb
    app/javascript/**/*.js
  ].freeze

  # Each waits for its view batch (#544–#547). Text on a strong fill moves onto Kit::Button or
  # Kit::Chip; a mark with no text (a dot, a bar, a tick) needs a domain token instead.
  ALLOWED = {
    # A Shell surface: tone-warning pairs its text, and the focus ring follows it
    "app/components/shell/impersonation_banner.rb" => %w[bg-tone-strong],
    # Text on the fill
    "app/views/calibration_sessions/show_view.rb" => %w[bg-neutral-strong],
    "app/views/assessments/category_chip_bar.rb" => %w[aria-[current=page]:bg-neutral-strong],
    "app/views/assessments/activity/filter_chips.rb" => %w[aria-pressed:bg-neutral-strong],
    "app/views/assessments/level_chip.rb" => %w[bg-neutral-strong],
    "app/views/notifications/bell.rb" => %w[bg-tone-strong],
    # The sign-in page's 44px Log in keeps its own size and radius, which Kit::Button lacks
    "app/views/users/sessions/new_view.rb" => %w[bg-tone-strong hover:bg-tone-strong-hover],
    # Marks with no text
    "app/views/calibration_sessions/cohort_view.rb" => %w[bg-neutral-strong],
    "app/views/assessments/hero_summary.rb" => %w[bg-neutral-strong bg-warning-strong],
    "app/views/assessments/category_indicators.rb" => %w[bg-warning-strong],
    "app/views/assessment_cycles/evidence_report/show_view.rb" => %w[bg-info-strong],
    "app/views/notifications/row.rb" => %w[bg-info-strong]
  }.freeze

  should "keep strong fills inside Kit components" do
    found = SOURCES.flat_map { |glob| Dir[Rails.root.join(glob)] }.to_h do |path|
      [ relative(path), File.readlines(path).each_with_index.flat_map { |line, i| line.scan(STRONG_FILL).map { [ _1, i + 1 ] } } ]
    end

    offenders = found.flat_map do |path, hits|
      hits.reject { |fill, _| ALLOWED.fetch(path, []).include?(fill) }.map { |fill, line| "#{path}:#{line} #{fill}" }
    end
    stale = ALLOWED.flat_map { |path, fills| (fills - found.fetch(path, []).map(&:first)).map { "#{path} #{_1}" } }

    assert_empty offenders, "Render the strong fill through a Kit component (Button, Chip, Alert):\n#{offenders.join("\n")}"
    assert_empty stale, "Gone from the file, so drop it from ALLOWED:\n#{stale.join("\n")}"
  end

  private

  def relative(path)
    Pathname(path).relative_path_from(Rails.root).to_s
  end
end
