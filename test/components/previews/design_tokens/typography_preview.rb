# frozen_string_literal: true

# @label Typography
class DesignTokens::TypographyPreview < Lookbook::Preview
  STYLESHEET = Rails.root.join("app/assets/tailwind/application.css")
  SAMPLE = "Consistently demonstrates the behaviours expected at this level."

  # Literal class names so Tailwind's scanner emits them.
  SIZES = %w[text-xs text-sm text-base text-lg text-xl text-2xl text-3xl].freeze
  WEIGHTS = %w[font-normal font-medium font-semibold font-bold].freeze
  COPY_COLOURS = {
    "text-default" => "Body copy and headings.",
    "text-muted" => "Muted copy: the AA pairing for secondary text."
  }.freeze

  def font_family
    render_with_template(locals: { declared: declared_font_sans, sample: SAMPLE })
  end

  def sizes
    render_with_template(
      template: "design_tokens/typography_preview/samples",
      locals: { title: "Sizes", classes: SIZES, sample: SAMPLE, measure: true }
    )
  end

  def weights
    render_with_template(
      template: "design_tokens/typography_preview/samples",
      locals: { title: "Weights", classes: WEIGHTS, sample: SAMPLE, measure: false }
    )
  end

  def copy_colours
    render_with_template(locals: { colours: COPY_COLOURS })
  end

  private

  def declared_font_sans
    STYLESHEET.read[/^\s*--font-sans:\s*(.+?);/, 1]
  end
end
