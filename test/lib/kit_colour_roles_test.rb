# frozen_string_literal: true

require "test_helper"

# Kit, Shell and Shared, and the controllers that write their class strings,
# colour themselves with the role utilities in theme/roles.css (#543), so a
# theme reaches them. A palette step is a colour no theme can set.
class KitColourRolesTest < ActiveSupport::TestCase
  HUES = %w[slate gray zinc neutral stone red orange amber yellow lime green emerald teal cyan sky blue
            indigo violet purple fuchsia pink rose].freeze
  COLOUR = /(?:white|black|primary(?:-ink)?|secondary|nav-(?:fg|bg)|(?:#{HUES.join('|')})-\d{2,3})/
  PALETTE_UTILITY = %r{(?<![\w-])(?:[^\s"'`:]+:)*!?(?:bg|text|border(?:-[xytrbl])?|divide|ring(?:-offset)?|outline|
                       decoration|fill|stroke|from|via|to|placeholder|accent|caret|shadow)-#{COLOUR}(?:/\d+)?(?![\w-])}x
  PALETTE_VARIABLE = /var\(--color-#{COLOUR}\)/

  SOURCES = %w[
    app/components/kit/**/*.rb
    app/components/shell/**/*.rb
    app/components/shared/**/*.rb
    app/javascript/controllers/evidence_modal_controller.js
    app/javascript/controllers/category_nav_controller.js
    app/javascript/controllers/tree_controller.js
    app/javascript/controllers/field_editor_controller.js
    app/javascript/controllers/explorer_menu_controller.js
  ].freeze

  should "colour Kit, Shell, Shared and their controllers with role utilities" do
    offenders = SOURCES.flat_map { |glob| Dir[Rails.root.join(glob)] }.flat_map do |path|
      code_lines(path).flat_map do |line, number|
        line.scan(PALETTE_UTILITY).map { |utility| "#{relative(path)}:#{number} #{utility}" }
      end
    end

    assert_empty offenders, "Use a role utility from theme/roles.css instead of:\n#{offenders.join("\n")}"
  end

  should "colour the Kit and explorer component classes with role variables" do
    css = Rails.root.join("app/assets/tailwind/application.css").read
    offenders = css.scan(/^([^{}\n]*\.(?:kit|explorer)-[^{}]*)\{([^}]*)\}/).flat_map do |selector, body|
      body.scan(PALETTE_VARIABLE).map { |variable| "#{selector.strip} #{variable}" }
    end

    assert_empty offenders, "Use a --gos-* role variable instead of:\n#{offenders.join("\n")}"
  end

  private

  def code_lines(path)
    File.readlines(path).each_with_index.filter_map do |line, i|
      [ line, i + 1 ] unless line.lstrip.start_with?("#", "//")
    end
  end

  def relative(path)
    Pathname(path).relative_path_from(Rails.root).to_s
  end
end
