# frozen_string_literal: true

require "test_helper"

# The mechanism, not the wording: the tip has to be reachable by keyboard and
# announced as the term's description. A definition nobody can open is the
# same as no definition.
class Components::Kit::DefinitionTipTest < ActiveSupport::TestCase
  def render_tip(**overrides)
    Components::Kit::DefinitionTip.new(
      "Self-gap",
      **{ definition: "Mean of (manager − self).", id: "deftip-self-gap" }.merge(overrides)
    ).call
  end

  should "render the term and its definition" do
    html = render_tip

    assert_includes html, "Self-gap"
    assert_includes html, "Mean of (manager − self)."
  end

  should "make the trigger focusable and wire it to the panel" do
    html = render_tip

    assert_includes html, "<button", "a non-focusable trigger is unreachable by keyboard"
    assert_includes html, %(aria-describedby="deftip-self-gap")
    assert_includes html, %(id="deftip-self-gap")
    assert_includes html, %(role="tooltip")
  end

  should "reveal on focus as well as hover" do
    html = render_tip

    assert_includes html, "group-hover/deftip:block"
    assert_includes html, "group-focus-within/deftip:block",
      "hover-only leaves the keyboard-driving facilitator with nothing"
  end

  should "escape a clipping ancestor via the top layer" do
    html = render_tip

    # The tendency table scrolls horizontally, and an overflow ancestor
    # clips on BOTH axes — without the popover the definition is cut in half.
    assert_includes html, %(popover="manual")
    assert_includes html, "[&:popover-open]:block"
    assert_includes html, %(data-controller="definition-tip")
    assert_includes html, %(data-definition-tip-target="panel")
    assert_includes html, %(data-definition-tip-target="trigger")
  end

  should "draw the info glyph rather than typing it" do
    # U+24D8 rendered as a tofu box in the headless browser's font, on a
    # surface whose whole job is legibility on a projector.
    html = render_tip

    assert_includes html, "<svg"
    assert_not_includes html, "ⓘ"
  end

  should "keep the tap target and focus ring when a caller restyles the trigger" do
    html = render_tip(trigger_class: "rounded-full bg-amber-100")

    assert_includes html, "bg-amber-100"
    assert_includes html, "focus-visible:ring-primary"
    assert_not_includes html, "decoration-dotted", "the caller's styling replaces the default"
  end

  should "use the caller's id verbatim, so repeated terms stay distinct" do
    # aria-describedby points at an id: two terms sharing one makes both
    # references ambiguous, and the glossary renders `spread` once per
    # capability row.
    assert_includes render_tip(id: "calibration-term-spread-abc"),
                    %(id="calibration-term-spread-abc")
  end

  should "flip the panel for a term near the right edge" do
    assert_includes render_tip(align: :right), "right-0"
    assert_includes render_tip, "left-0"
  end
end
