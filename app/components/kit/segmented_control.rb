# frozen_string_literal: true

# One choice from a few, on a shared track. The chosen segment lifts onto the card fill, never
# brand (#543), so a Stimulus controller only has to flip the segment's state attribute.
#
# Segments are buttons with `aria-pressed` in a labelled group. Inside a `role="menu"`, where every
# control must be a menu item, `item_role: :menuitemradio` gives them `aria-checked` instead.
#
# @example
#   render Components::Kit::SegmentedControl.new(label: "Activity feed focus mode", size: :sm) do |control|
#     control.segment("Highlight", data: { action: "activity-feed#setMode" })
#     control.segment("Filter", selected: true, data: { action: "activity-feed#setMode" })
#   end
class Components::Kit::SegmentedControl < Components::Base
  TRACK = "items-stretch gap-0.5 rounded-full bg-neutral-muted p-0.5"

  SEGMENT = "inline-flex items-center justify-center rounded-full font-medium whitespace-nowrap text-muted " \
            "cursor-pointer select-none transition-colors enabled:hover:text-default " \
            "focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-focus " \
            "aria-pressed:bg-default aria-pressed:font-semibold aria-pressed:text-default " \
            "aria-checked:bg-default aria-checked:font-semibold aria-checked:text-default " \
            "disabled:cursor-not-allowed disabled:text-disabled"

  SIZES = {
    sm: "min-h-6 px-2.5 text-xs",
    md: "min-h-8 px-3 text-[13px]"
  }.freeze

  # @param label [String, nil] the group's accessible name; pass `aria: { labelledby: }` for a visible label
  # @param size [Symbol] :sm or :md
  # @param fill [Boolean] stretch the track to its container and share the width between segments
  # @param item_role [Symbol, nil] :menuitemradio inside a menu; segments are plain buttons otherwise
  # @param attrs [Hash] passed through to the track; `class:` is appended
  def initialize(label: nil, size: :md, fill: false, item_role: nil, **attrs)
    @label = label
    @size = SIZES.fetch(size)
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
  # @param disabled [Boolean]
  # @param attrs [Hash] passed through to the segment's button
  def segment(label, selected: false, disabled: false, **attrs)
    button(**mix({ type: "button", disabled: disabled, class: "#{SEGMENT} #{@size}#{" flex-1" if @fill}" },
                 state(selected), attrs)) { plain label }
  end

  private

  def state(selected)
    if @item_role == :menuitemradio
      { role: "menuitemradio", aria: { checked: selected.to_s } }
    else
      { aria: { pressed: selected.to_s } }
    end
  end
end
