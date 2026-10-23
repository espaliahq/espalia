# frozen_string_literal: true

# @label Colours
class DesignTokens::ColoursPreview < Lookbook::Preview
  STYLESHEET = Rails.root.join("app/assets/tailwind/application.css")

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
      locals: { title: "Brand tokens", tokens: brand_tokens }
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

  def declarations(lines)
    lines.filter_map do |line|
      match = line.match(/\A\s*(--[\w-]+):\s*(.+?);\s*\z/)
      [ match[1], match[2] ] if match
    end
  end
end
