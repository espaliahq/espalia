# frozen_string_literal: true

# @label Button
class Kit::ButtonPreview < Lookbook::Preview
  Button = Components::Kit::Button
  FORMS = Button::VARIANTS.keys
  TONES = Button::TONES.keys
  STATES = { rest: "", hover: "hover:", pressed: "active:" }.freeze
  ROLES = Rails.root.join("app/assets/tailwind/theme/roles.css")

  # @param label text
  # @param variant select { choices: [solid, subtle, outline, ghost, link] }
  # @param tone select { choices: [neutral, brand, danger, success, warning, info] }
  # @param size select { choices: [xs, sm, md] }
  # @param touch toggle
  # @param disabled toggle
  # @param href text
  def playground(label: "Save ratings", variant: :solid, tone: :neutral, size: :md, touch: false, disabled: false, href: "")
    render Button.new(
      variant: variant.to_sym, tone: tone.to_sym, size: size.to_sym, touch: touch, disabled: disabled,
      href: href.presence
    ) { label }
  end

  # Every form × tone, on a card and on the page, with each state's text measured on its fill as painted.
  # Hover and pressed read the colours from the component's own hover: and active: classes.
  def contrast
    render_with_template(locals: { forms: FORMS, tones: TONES, states: contrast_states })
  end

  # @!group Forms × tones

  def solid = tone_row(:solid)
  def subtle = tone_row(:subtle)
  def outline = tone_row(:outline)
  def ghost = tone_row(:ghost)
  def link = tone_row(:link)

  # @!endgroup

  # @!group Sizes

  def sizes
    render_with_template(locals: { sizes: Button::SIZES.keys })
  end

  # At least 44px square, for touch: every size grows to the same target
  def touch
    render_with_template(template: "kit/button_preview/sizes", locals: { sizes: Button::SIZES.keys, touch: true })
  end

  # @!endgroup

  # @!group Icon only

  def icon_only
    render_with_template(locals: { sizes: Button::SIZES.keys })
  end

  # @!endgroup

  # @!group States

  # Disabled solid and subtle buttons share one neutral fill; the rest drop to disabled text
  def disabled
    render_with_template(locals: { forms: FORMS })
  end

  # A link that looks like a button: disabled, it loses its href and takes aria-disabled
  def as_a_link
    render_with_template
  end

  # @!endgroup

  # @!group In use

  def dialog_footer = render_with_template
  def destructive_confirm = render_with_template
  def quiet_toolbar = render_with_template
  def row_link = render_with_template

  # @!endgroup

  private

  def tone_row(form)
    render_with_template(template: "kit/button_preview/tone_row", locals: { form: form, tones: TONES })
  end

  # { [form, tone] => { state => [fill, text] } }, CSS colour expressions read from the component's classes.
  def contrast_states
    FORMS.product(TONES).to_h do |form, tone|
      tokens = Button.classes(variant: form, tone: tone).split
      rest = colours(tokens, "")
      [ [ form, tone ], STATES.transform_values { |prefix| colours(tokens, prefix).merge(rest) { |_, mine, base| mine || base } } ]
    end
  end

  def colours(tokens, prefix)
    picked = tokens.filter_map { |token| token.delete_prefix(prefix) if prefix.empty? ? !token.include?(":") : token.start_with?(prefix) }
    { fill: colour(picked, "bg"), text: colour(picked, "text") }
  end

  # bg-tone-strong → var(--gos-tone-strong); bg-(--x) → var(--x); text-[color-mix(…)] → color-mix(…). Nil when unset.
  def colour(utilities, kind)
    utilities.each do |utility|
      value = utility[/\A#{kind}-(.+)\z/, 1] or next
      return "transparent" if value == "transparent"
      return "var(#{$1})" if value =~ /\A\((--[\w-]+)\)\z/
      return $1.tr("_", " ") if value =~ /\A\[(.+)\]\z/

      role = role_utilities["#{kind}-#{value}"]
      return "var(#{role})" if role
    end
    nil
  end

  def role_utilities
    @role_utilities ||= ROLES.read.scan(/--(background|text)-color-([\w-]+):\s*var\((--gos-[\w-]+)\)/)
                             .to_h { |property, name, role| [ "#{property == "background" ? "bg" : "text"}-#{name}", role ] }
  end
end
