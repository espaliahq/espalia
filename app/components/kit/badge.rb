# frozen_string_literal: true

# A short status or count label. Square, so it reads apart from a fully rounded `Kit::Tag`.
# The form sets its weight; the tone carries its meaning.
#
# @example A status
#   render Components::Kit::Badge.new("Aligned", tone: :success)
#
# @example A solid count with an icon
#   render Components::Kit::Badge.new("3", variant: :solid, tone: :danger, leading_icon: "bell")
#
# @example A larger outline badge
#   render Components::Kit::Badge.new("Draft", variant: :outline, size: :md)
#
class Components::Kit::Badge < Components::Base
  TONES = {
    neutral: "tone-neutral",
    brand: "tone-brand",
    info: "tone-info",
    success: "tone-success",
    warning: "tone-warning",
    danger: "tone-danger"
  }.freeze

  VARIANTS = {
    subtle: "border-transparent bg-tone-subtle text-tone-content-strong",
    solid: "border-transparent bg-tone-strong text-tone-content-inverse",
    outline: "border-tone bg-transparent text-tone-content-strong"
  }.freeze

  SIZES = {
    sm: "h-5 px-1.5 text-xs",
    md: "h-6 px-2 text-[13px]"
  }.freeze

  ICON_SIZES = {
    sm: "size-3",
    md: "size-3.5"
  }.freeze

  # The job-named variants from before tones; each is a subtle badge in the matching tone
  LEGACY_VARIANTS = {
    default: :neutral,
    primary: :brand,
    info: :info,
    success: :success,
    warning: :warning
  }.freeze

  BASE = "inline-flex shrink-0 items-center gap-1 rounded-sm border font-medium leading-none " \
         "whitespace-nowrap tabular-nums"

  # The full class list, for a control that has to look like a badge without being one
  # (a `Kit::DefinitionTip` trigger).
  # @param variant [Symbol] :subtle, :solid or :outline (a legacy job name maps to a subtle tone)
  # @param tone [Symbol] :neutral, :brand, :info, :success, :warning or :danger
  # @param size [Symbol] :sm or :md
  # @return [String]
  def self.classes(variant = :subtle, tone: :neutral, size: :sm)
    variant, tone = resolve(variant, tone)
    [ BASE, TONES.fetch(tone), VARIANTS.fetch(variant), SIZES.fetch(size) ].join(" ")
  end

  # @return [Array(Symbol, Symbol)] the form and tone, with a legacy variant turned into its tone
  def self.resolve(variant, tone)
    LEGACY_VARIANTS.key?(variant) ? [ :subtle, LEGACY_VARIANTS[variant] ] : [ variant, tone ]
  end

  # @param label [String] the badge text
  # @param variant [Symbol] :subtle, :solid or :outline
  # @param tone [Symbol] :neutral, :brand, :info, :success, :warning or :danger
  # @param size [Symbol] :sm or :md
  # @param leading_icon [String, Symbol, nil] a sprite icon before the label
  # @param trailing_icon [String, Symbol, nil] a sprite icon after the label
  # @param attributes [Hash] extra attributes for the span, mixed with the badge's own
  def initialize(label, variant: :subtle, tone: :neutral, size: :sm, leading_icon: nil, trailing_icon: nil,
                 **attributes)
    @label = label
    @variant = variant
    @tone = tone
    @size = size
    @leading_icon = leading_icon
    @trailing_icon = trailing_icon
    @attributes = attributes
  end

  def view_template
    span(**mix({ class: self.class.classes(@variant, tone: @tone, size: @size) }, @attributes)) do
      badge_icon(@leading_icon) if @leading_icon
      plain @label
      badge_icon(@trailing_icon) if @trailing_icon
    end
  end

  private

  def badge_icon(name)
    icon(name, class: "#{ICON_SIZES.fetch(@size)} shrink-0")
  end
end
