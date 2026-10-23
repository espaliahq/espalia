# frozen_string_literal: true

# A button, or a link that looks like one. The variant is its form and the tone its meaning;
# the component owns the fill and its text, so call sites never choose colours.
#
# @example The main action on a view
#   render Components::Kit::Button.new(tone: :brand, type: :submit) { "Save ratings" }
#
# @example A link that looks like a button
#   render Components::Kit::Button.new(variant: :outline, href: assessment_path(assessment)) { "Open" }
#
# @example Icon only
#   render Components::Kit::Button.new(variant: :ghost, icon: true, aria_label: "Edit") { icon(:pencil, class: "size-4") }
#
# @example On a `button_to`
#   button_to "Delete", path, method: :delete, class: Components::Kit::Button.classes(tone: :danger)
#
# @example On an `f.submit`, an input that can't carry the hit area, so it is 44px to the eye
#   f.submit "Save", class: Components::Kit::Button.classes(tone: :brand, touch: true)
#
class Components::Kit::Button < Components::Base
  BASE = "inline-flex shrink-0 items-center justify-center gap-1.5 rounded-md border " \
         "font-medium whitespace-nowrap cursor-pointer select-none transition-colors " \
         "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus " \
         "disabled:cursor-not-allowed aria-disabled:cursor-not-allowed"

  TONES = {
    neutral: "tone-neutral",
    brand: "tone-brand",
    danger: "tone-danger",
    success: "tone-success",
    # Its strong fill carries dark text, so pressing lightens it rather than darkening it
    warning: "tone-warning [--btn-pressed-strong:color-mix(in_oklab,var(--gos-warning-strong)_70%,white)]",
    info: "tone-info"
  }.freeze

  VARIANTS = {
    solid: "border-transparent bg-tone-strong text-tone-content-inverse hover:bg-tone-strong-hover " \
           "active:bg-[var(--btn-pressed-strong,color-mix(in_oklab,var(--gos-tone-strong-hover)_85%,black))] " \
           "disabled:bg-neutral-subtle disabled:text-disabled aria-disabled:bg-neutral-subtle aria-disabled:text-disabled",
    subtle: "border-transparent bg-tone-subtle text-tone-content-strong hover:bg-tone-muted " \
            "active:bg-[color-mix(in_oklab,var(--gos-tone-muted)_88%,var(--gos-tone-content-strong))] " \
            "active:text-[color-mix(in_oklab,var(--gos-tone-content-strong)_70%,var(--gos-content-default))] " \
            "disabled:bg-neutral-subtle disabled:text-disabled aria-disabled:bg-neutral-subtle aria-disabled:text-disabled",
    outline: "bg-default border-tone text-tone-content-strong hover:bg-tone-subtle active:bg-tone-muted " \
             "disabled:bg-default disabled:border-disabled disabled:text-disabled " \
             "aria-disabled:bg-default aria-disabled:border-disabled aria-disabled:text-disabled",
    ghost: "border-transparent bg-transparent text-tone-content-strong hover:bg-tone-subtle active:bg-tone-muted " \
           "disabled:bg-transparent disabled:text-disabled aria-disabled:bg-transparent aria-disabled:text-disabled",
    link: "border-transparent text-tone-content-strong underline decoration-1 underline-offset-3 hover:decoration-2 " \
          "active:decoration-2 active:text-[color-mix(in_oklab,var(--gos-tone-content-strong)_80%,var(--gos-content-default))] " \
          "disabled:no-underline disabled:text-disabled aria-disabled:no-underline aria-disabled:text-disabled"
  }.freeze

  SIZES = {
    xs: "h-6 px-2 text-xs",
    sm: "h-8 px-2.5 text-sm",
    md: "h-9 px-3.5 text-sm"
  }.freeze

  ICON_SIZES = {
    xs: "size-6 text-xs",
    sm: "size-8 text-sm",
    md: "size-9 text-sm"
  }.freeze

  # A link's size is only its type; it takes the 44px hit area like any button, and in a sentence passes compact.
  LINK_SIZES = {
    xs: "min-h-6 px-0.5 text-xs",
    sm: "min-h-6 px-0.5 text-sm",
    md: "min-h-6 px-0.5 text-sm"
  }.freeze

  TOUCH = "min-h-11 min-w-11"

  # An invisible box, centred and at least 44px square, takes the tap so the visual can stay small.
  HIT_AREA = "relative after:absolute after:top-1/2 after:left-1/2 after:size-full after:min-h-11 after:min-w-11 " \
             "after:-translate-x-1/2 after:-translate-y-1/2"

  # The class string for a variant, tone and size, for a `button_to`, `f.submit` or `link_to`
  # that can't render the component.
  # @param variant [Symbol] :solid, :subtle, :outline, :ghost or :link
  # @param tone [Symbol] :neutral, :brand, :danger, :success, :warning or :info
  # @param size [Symbol] :xs, :sm or :md
  # @param touch [Boolean] at least 44px square to the eye, for a touch target
  # @param compact [Boolean] the hit area is only the visual, for a dense group, a link in a sentence or a larger target around it
  # @param icon [Boolean] square, for an icon on its own
  # @return [String]
  def self.classes(variant: :solid, tone: :neutral, size: :md, touch: false, compact: false, icon: false)
    sizes = if variant == :link then LINK_SIZES elsif icon then ICON_SIZES else SIZES end
    hit_area = HIT_AREA unless touch || compact
    [ BASE, TONES.fetch(tone), VARIANTS.fetch(variant), sizes.fetch(size), (TOUCH if touch), hit_area ].compact.join(" ")
  end

  # @param variant [Symbol] the form: :solid, :subtle, :outline, :ghost or :link
  # @param tone [Symbol] the meaning: :neutral, :brand, :danger, :success, :warning or :info
  # @param size [Symbol] :xs, :sm or :md
  # @param touch [Boolean] at least 44px square to the eye, for a touch target
  # @param compact [Boolean] the hit area is only the visual, for a dense group, a link in a sentence or a larger target around it
  # @param icon [Boolean] square, for an icon on its own; needs `aria_label:`
  # @param href [String, nil] renders an `a` instead of a `button`
  # @param type [Symbol] the button's type; ignored with `href:`
  # @param disabled [Boolean] a disabled `a` loses its `href` and takes `aria-disabled`
  # @param aria_label [String, nil] the accessible name, required with `icon:`
  # @param attrs [Hash] passed through to the element; `class:` is appended
  # @raise [ArgumentError] for `icon: true` without `aria_label:`
  def initialize(variant: :solid, tone: :neutral, size: :md, touch: false, compact: false, icon: false, href: nil,
                 type: :button, disabled: false, aria_label: nil, **attrs)
    raise ArgumentError, "an icon-only Kit::Button needs aria_label:" if icon && aria_label.blank?

    @classes = self.class.classes(variant: variant, tone: tone, size: size, touch: touch, compact: compact, icon: icon)
    @href = href
    @type = type
    @disabled = disabled
    @aria_label = aria_label
    @attrs = attrs
  end

  def view_template(&)
    if @href
      a(**element_attrs, href: (@href unless @disabled), aria: aria_attrs(disabled: ("true" if @disabled)), &)
    else
      button(**element_attrs, type: @type, disabled: @disabled, aria: aria_attrs, &)
    end
  end

  private

  def element_attrs
    @attrs.except(:aria).merge(class: [ @classes, @attrs[:class] ].compact.join(" "))
  end

  def aria_attrs(**extra)
    { **@attrs.fetch(:aria, {}), **{ label: @aria_label }.compact, **extra }.compact
  end
end
