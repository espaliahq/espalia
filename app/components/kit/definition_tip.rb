# frozen_string_literal: true

# A term that carries its own definition — shown on hover AND on keyboard
# focus, never hover-only.
#
# Built for surfaces that invent a vocabulary and then get projected in a
# room (the calibration session screens): the facilitator may be driving by
# keyboard, and nobody else can hover on their behalf. Deliberately NOT the
# native `title` attribute, which no keyboard user can reach.
#
# The trigger is a real `<button>` (focusable, announced) wired to the panel
# with `aria-describedby`, so a screen reader reads the definition as the
# term's description rather than as loose text after it.
#
# @example
#   render Components::Kit::DefinitionTip.new(
#     "Self-gap", definition: "Mean of (manager − self) …", id: "deftip-self-gap"
#   )
class Components::Kit::DefinitionTip < Components::Base
  DEFAULT_TRIGGER = "inline-flex min-h-11 items-center text-left underline decoration-dotted " \
                    "decoration-(--gos-content-subtle) underline-offset-4 hover:decoration-(--gos-content-default)"

  FOCUS = "rounded-md focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-focus"

  # @param term [String] the word as it reads in the UI
  # @param definition [String] one or two sentences, plain language
  # @param id [String] unique per page — wires `aria-describedby`
  # @param align [Symbol] :left or :right — flip near the viewport edge so a
  #   panel on a right-hand column isn't clipped
  # @param trigger_class [String, nil] replaces the default underlined-term
  #   styling, for a term that already has a visual form of its own (a badge,
  #   a legend swatch). The focus ring and tap target are added either way.
  def initialize(term, definition:, id:, align: :left, trigger_class: nil)
    @term = term
    @definition = definition
    @id = id
    @align = align
    @trigger_class = trigger_class
  end

  # Renders the term and its (hidden until hover/focus) definition panel.
  #
  # @return [void]
  def view_template
    span(class: "group/deftip relative inline-flex", data: { controller: "definition-tip" }) do
      trigger
      panel
    end
  end

  private

  # `min-h-11` keeps the tap target at the house minimum even though the
  # term itself is small type — this is a standalone control, not a link
  # inside a sentence.
  def trigger
    button(
      type: "button",
      class: "#{@trigger_class || DEFAULT_TRIGGER} #{FOCUS}",
      aria: { describedby: @id },
      data: { definition_tip_target: "trigger" }
    ) do
      plain @term
      info_glyph
    end
  end

  # Drawn, not typed: the headless/-shell font on some machines has no ⓘ
  # (U+24D8) and rendered a tofu box in its place — on a surface whose whole
  # job is to be legible on a projector.
  def info_glyph
    svg(
      class: "ml-0.5 h-2.5 w-2.5 shrink-0 opacity-60", viewbox: "0 0 16 16",
      fill: "currentColor", aria: { hidden: "true" }
    ) do |s|
      s.path(
        fill_rule: "evenodd",
        d: "M8 1a7 7 0 100 14A7 7 0 008 1zM7 6.5A1 1 0 118 5.5a1 1 0 01-1 1zm" \
           "-.25 1.75h1.5v4h-1.5v-4z"
      )
    end
  end

  # Hidden until hover or focus. `popover` puts it in the top layer, out of
  # reach of any clipping ancestor (the tendency table scrolls horizontally,
  # which clips on BOTH axes); the Stimulus controller opens and positions
  # it. The group-hover/focus-within classes stay as the no-JS fallback, and
  # are written as literals because Tailwind scans source for class names
  # (framework-explorer.md, Hard-Won Lesson 12).
  def panel
    span(
      id: @id,
      role: "tooltip",
      popover: "manual",
      data: { definition_tip_target: "panel" },
      class: "pointer-events-none absolute top-full z-30 mt-1 hidden w-64 rounded-md " \
             "border border-default bg-overlay " \
             "px-3 py-2 text-xs font-normal normal-case tracking-normal " \
             "text-muted shadow-lg [&:popover-open]:block " \
             "group-hover/deftip:block group-focus-within/deftip:block #{alignment}"
    ) { @definition }
  end

  def alignment
    @align == :right ? "right-0" : "left-0"
  end
end
