# frozen_string_literal: true

require "test_helper"

# A role utility that points at an undefined variable renders no colour at all,
# and one named like an existing colour (text-secondary from --color-secondary)
# makes Tailwind emit both, so the class means two things (ADR-23).
class ThemeRolesTest < ActiveSupport::TestCase
  THEME_DIR = Rails.root.join("app/assets/tailwind/theme")
  APPLICATION_CSS = Rails.root.join("app/assets/tailwind/application.css")
  # Unstepped colours and the font-size scale: text-white, text-lg and the like already exist.
  TAILWIND_NAMES = (%w[black white transparent current inherit xs sm base lg xl] + (2..9).map { |n| "#{n}xl" }).to_set
  UTILITY = /^\s*--(?:text|background|border|ring|outline)-color-([\w-]+):\s*var\((--gos-[\w-]+)\)/

  def theme_css
    Dir[THEME_DIR.join("*.css")].map { |path| File.read(path) }.join("\n")
  end

  def utilities
    theme_css.scan(UTILITY)
  end

  should "point every role utility at a variable a theme file defines" do
    defined = theme_css.scan(/^\s*(--gos-[\w-]+):/).flatten.to_set
    undefined = utilities.reject { |_, variable| defined.include?(variable) }
    assert_empty undefined, "Role utilities with no variable behind them:\n#{undefined.map(&:join).join("\n")}"
  end

  should "not name a role after an existing utility" do
    taken = File.read(APPLICATION_CSS).scan(/^\s*--color-([\w-]+):/).flatten.to_set + TAILWIND_NAMES
    clashes = utilities.map(&:first).select { |name| taken.include?(name) }
    assert_empty clashes, "These role names already mean something to Tailwind: #{clashes.join(", ")}"
  end
end
