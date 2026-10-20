# frozen_string_literal: true

# @label Colours
class DesignTokens::ColoursPreview < Lookbook::Preview
  STYLESHEET = Rails.root.join("app/assets/tailwind/application.css")
  COLOUR_VALUE = /\A(#|rgb|hsl|oklch|oklab|color-mix|var\(--)/
  SIGN_IN_SELECTOR = "html:has(.auth-page) {"

  # Literal class names so Tailwind's scanner emits them.
  PALETTE = {
    "Gray" => %w[bg-gray-50 bg-gray-100 bg-gray-200 bg-gray-300 bg-gray-400 bg-gray-500
                 bg-gray-600 bg-gray-700 bg-gray-800 bg-gray-900 bg-gray-950],
    "Green" => %w[bg-green-100 bg-green-300 bg-green-500 bg-green-700 bg-green-900],
    "Amber" => %w[bg-amber-100 bg-amber-300 bg-amber-500 bg-amber-700 bg-amber-900],
    "Red" => %w[bg-red-100 bg-red-300 bg-red-500 bg-red-700 bg-red-900],
    "Blue" => %w[bg-blue-100 bg-blue-300 bg-blue-500 bg-blue-700 bg-blue-900]
  }.freeze

  # The app's colour tokens: the @theme block and the :root blocks under it.
  def brand
    render_with_template(
      template: "design_tokens/colours_preview/swatches",
      locals: { title: "Brand tokens", tokens: brand_tokens, scope_class: nil, scoped_css: nil }
    )
  end

  # The sign-in page's Bento tokens, re-declared on a wrapper so they resolve outside `.auth-page`.
  def sign_in
    light, dark = sign_in_declarations
    render_with_template(
      template: "design_tokens/colours_preview/swatches",
      locals: {
        title: "Sign-in page (Bento, page-scoped)",
        tokens: colour_names(light),
        scope_class: "tokens-sign-in",
        scoped_css: scoped_css(".tokens-sign-in", light, dark)
      }
    )
  end

  def tailwind_palette
    render_with_template(template: "design_tokens/colours_preview/palette", locals: { palette: PALETTE })
  end

  private

  def stylesheet_lines
    STYLESHEET.read.lines
  end

  # From `@theme {` to the first top-level rule that is not a scheme or support variant of it.
  def brand_tokens
    lines = stylesheet_lines.drop_while { |line| !line.start_with?("@theme {") }
    region = lines.take_while.with_index do |line, i|
      i.zero? || line.match?(/\A(\s|\}|@media|@supports|:root|\z)/)
    end
    declarations(region).map(&:first).uniq.reject { |name| name.start_with?("--font-") }
  end

  def sign_in_declarations
    light = []
    dark = []
    in_dark = false
    in_block = false
    stylesheet_lines.each do |line|
      in_dark = true if line.start_with?("@media (prefers-color-scheme: dark)")
      in_dark = false if line.start_with?("}") && !in_block
      if line.strip == SIGN_IN_SELECTOR
        in_block = true
      elsif in_block && line.strip == "}"
        in_block = false
      elsif in_block
        (in_dark ? dark : light).concat(declarations([ line ]).select { |name, _| name.start_with?("--auth-") })
      end
    end
    [ light, dark ]
  end

  def declarations(lines)
    lines.filter_map do |line|
      match = line.match(/\A\s*(--[\w-]+):\s*(.+?);\s*\z/)
      [ match[1], match[2] ] if match
    end
  end

  def colour_names(declarations)
    declarations.select { |_, value| value.match?(COLOUR_VALUE) }.map(&:first)
  end

  def scoped_css(selector, light, dark)
    body = ->(decls) { decls.map { |name, value| "#{name}: #{value};" }.join(" ") }
    "#{selector} { #{body.call(light)} } " \
      "@media (prefers-color-scheme: dark) { #{selector} { #{body.call(dark)} } }"
  end
end
