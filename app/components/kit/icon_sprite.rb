# frozen_string_literal: true

# The ONE `<symbol>` set for the app's repeated inline icons, rendered once per
# page by {Components::Shell::PageLayout}. Call sites emit
# `<svg class="…"><use href="#icon-pencil"/></svg>` via
# {Components::Helpers::IconHelpers#icon} instead of a full path definition.
#
# Why: the framework explorer's edit matrix rendered the same handful of glyphs
# thousands of times — 758 `<svg>` elements, 218 KB (18% of the frame), of which
# 374 were the identical pencil path and 282 the identical speech bubble. A
# sprite makes each call site ~55 bytes regardless of how intricate the glyph is
# (#380).
#
# Presentation attributes (viewBox, fill, stroke, stroke-width, line joins) live
# on the `<symbol>`, so a call site only supplies size/colour classes;
# `currentColor` still resolves against the referencing element, so `text-…`
# utilities keep working exactly as they did on an inline `<svg>`.
class Components::Kit::IconSprite < Components::Base
  # Stroked outline glyphs on the 24×24 grid (Heroicons-style). Each value is
  # the `d` of a single path — a glyph needing several paths belongs in
  # {MULTI_PATH_ICONS}.
  STROKE_ICONS = {
    "pencil" => "M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5" \
                "m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z",
    "discuss" => "M21 11.5a8.38 8.38 0 01-.9 3.8 8.5 8.5 0 01-7.6 4.7 8.38 8.38 0 01-3.8-.9L3 21l1.9-5.7a8.38 " \
                 "8.38 0 01-.9-3.8 8.5 8.5 0 014.7-7.6 8.38 8.38 0 013.8-.9h.5a8.48 8.48 0 018 8v.5z",
    "chevron-right" => "M9 5l7 7-7 7",
    "chevron-up" => "M4.5 15.75l7.5-7.5 7.5 7.5",
    "chevron-down" => "M19.5 8.25l-7.5 7.5-7.5-7.5",
    "plus" => "M12 4v16m8-8H4",
    "x" => "M6 18L18 6M6 6l12 12",
    "archive" => "M20.25 7.5l-.625 10.632a2.25 2.25 0 01-2.247 2.118H6.622a2.25 2.25 0 " \
                 "01-2.247-2.118L3.75 7.5M10 11.25h4M3.375 7.5h17.25c.621 0 1.125-.504 " \
                 "1.125-1.125v-1.5c0-.621-.504-1.125-1.125-1.125H3.375c-.621 0-1.125.504-1.125 " \
                 "1.125v1.5c0 .621.504 1.125 1.125 1.125z"
  }.freeze

  # Solid glyphs on the 20×20 grid.
  FILL_ICONS = {
    "kebab" => "M10 6a2 2 0 110-4 2 2 0 010 4zm0 2a2 2 0 100 4 2 2 0 000-4zm0 6a2 2 0 100 4 2 2 0 000-4z"
  }.freeze

  NAMES = (STROKE_ICONS.keys + FILL_ICONS.keys).freeze

  def view_template
    # aria-hidden + display:none: the sprite is a definition set, never content.
    # `display:none` on the host <svg> does NOT stop a <use> elsewhere from
    # resolving its symbols.
    svg(
      xmlns: "http://www.w3.org/2000/svg",
      class: "hidden",
      aria: { hidden: "true" },
      focusable: "false"
    ) do |s|
      s.defs do
        STROKE_ICONS.each { |name, d| stroke_symbol(s, name, d) }
        FILL_ICONS.each { |name, d| fill_symbol(s, name, d) }
      end
    end
  end

  private

  def stroke_symbol(s, name, path)
    s.symbol(
      id: "icon-#{name}", viewBox: "0 0 24 24",
      fill: "none", stroke: "currentColor", stroke_width: "2",
      stroke_linecap: "round", stroke_linejoin: "round"
    ) { s.path(d: path) }
  end

  def fill_symbol(s, name, path)
    s.symbol(id: "icon-#{name}", viewBox: "0 0 20 20", fill: "currentColor") do
      s.path(d: path)
    end
  end
end
