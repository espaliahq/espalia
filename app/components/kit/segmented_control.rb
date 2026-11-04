# frozen_string_literal: true

# One choice from a few, on a shared track. The chosen segment lifts onto the card fill, never
# brand (#543), so a Stimulus controller only has to flip the segment's state attribute.
#
# Segments are buttons with `aria-pressed` in a labelled group. Inside a `role="menu"`, where every
# control must be a menu item, `item_role: :menuitemradio` gives them `aria-checked` instead. A segment
# given `href:` is a link to that view of the page, marked `aria-current="page"` when selected.
#
# @example
#   render Components::Kit::SegmentedControl.new(label: "Activity feed focus mode", size: :sm) do |control|
#     control.segment("Highlight", data: { action: "activity-feed#setMode" })
#     control.segment("Filter", selected: true, data: { action: "activity-feed#setMode" })
#   end
class Components::Kit::SegmentedControl < Components::Base
  TRACK = "items-stretch gap-0.5 rounded-full bg-neutral-muted p-0.5"

  SEGMENT = "inline-flex items-center justify-center rounded-full font-medium whitespace-nowrap text-muted " \
            "cursor-pointer select-none transition-colors not-disabled:hover:text-default " \
            "focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-focus " \
            "aria-pressed:bg-default aria-pressed:font-semibold aria-pressed:text-default " \
            "aria-checked:bg-default aria-checked:font-semibold aria-checked:text-default " \
            "aria-[current=page]:bg-default aria-[current=page]:font-semibold aria-[current=page]:text-default " \
            "disabled:cursor-not-allowed disabled:text-disabled"

  SIZES = {
    sm: "px-2.5 text-xs",
    md: "px-3 text-[13px]"
  }.freeze

  # Compact under a mouse; a full 44px target on a touch screen
  HEIGHTS = { sm: "min-h-6 pointer-coarse:min-h-11", md: "min-h-8 pointer-coarse:min-h-11" }.freeze
  TOUCH = "min-h-11"

  # @param label [String, nil] the group's accessible name; pass `aria: { labelledby: }` for a visible label
  # @param size [Symbol] :sm or :md
  # @param fill [Boolean] stretch the track to its container and share the width between segments
  # @param item_role [Symbol, nil] :menuitemradio inside a menu; segments are plain buttons otherwise
  # @param touch [Boolean] segments at least 44px tall, for a touch target
  # @param attrs [Hash] passed through to the track; `class:` is appended
  def initialize(label: nil, size: :md, fill: false, item_role: nil, touch: false, **attrs)
    @label = label
    @size = "#{SIZES.fetch(size)} #{touch ? TOUCH : HEIGHTS.fetch(size)}"
    @fill = fill
    @item_role = item_role
    @attrs = attrs
  end

  def view_template(&)
    div(**mix({ role: "group", aria: { label: @label }.compact, class: "#{@fill ? "flex" : "inline-flex"} #{TRACK}" },
              @attrs)) { yield(self) }
  end

  # @param label [String]
  # @param selected [Boolean]
  # @param href [String, nil] makes the segment a link to that view
  # @param disabled [Boolean] buttons only
  # @param marked [String, nil] puts a dot after the label, saying something
  #   in that view needs attention; the string is what a screen reader hears
  # @param attrs [Hash] passed through to the segment's button or link
  def segment(label, selected: false, href: nil, disabled: false, marked: nil, **attrs)
    classes = { class: "#{SEGMENT} #{@size}#{" flex-1" if @fill}" }
    if href
      a(**mix(classes, { href: href, aria: { current: ("page" if selected) }.compact }, attrs)) { segment_label(label, marked) }
    else
      button(**mix(classes, { type: "button", disabled: disabled }, state(selected), attrs)) { segment_label(label, marked) }
    end
  end

  private

  def segment_label(label, marked)
    plain label
    return if marked.nil?

    span(class: "ml-1.5 size-2 shrink-0 rounded-full bg-neutral-strong", aria: { hidden: "true" }, data: { mark: true })
    span(class: "sr-only") { " (#{marked})" }
  end

  def state(selected)
    if @item_role == :menuitemradio
      { role: "menuitemradio", aria: { checked: selected.to_s } }
    else
      { aria: { pressed: selected.to_s } }
    end
  end
end
