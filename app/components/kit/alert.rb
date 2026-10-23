# frozen_string_literal: true

# A message in the page flow: an error, a warning, a confirmation or a note.
# The base owns the shape and type; colour comes only from the tone, so a
# call site picks what the message means, never what colour it is.
#
# @example A plain note
#   render Components::Kit::Alert.new { "Publishing v3…" }
#
# @example An error with a title and an action
#   render Components::Kit::Alert.new(tone: :danger, title: "The last publish failed") do |alert|
#     alert.action { a(href: mappings_path) { "Fix the mappings" } }
#     "Archived capability “Systems thinking” has no migration mapping."
#   end
#
# @example Dismissible, and gone by itself after 8 seconds
#   render Components::Kit::Alert.new(dismissible: true, dismiss_after: 8000) { "Ratings updated." }
#
class Components::Kit::Alert < Components::Base
  TONES = {
    neutral: "tone-neutral",
    info: "tone-info",
    success: "tone-success",
    warning: "tone-warning",
    danger: "tone-danger"
  }.freeze

  # A strong fill resets the focus ring to the tone's inverse content, which already clears 4.5:1 on it
  EMPHASES = {
    subtle: "bg-tone-subtle border-tone text-tone-content-strong",
    solid: "bg-tone-strong border-transparent text-tone-content-inverse " \
           "[--gos-focus-ring:var(--gos-tone-content-inverse)]"
  }.freeze

  SIZES = {
    sm: "gap-2 px-3 py-2 text-xs",
    md: "gap-3 px-4 py-3 text-sm"
  }.freeze

  ICON_SIZES = {
    sm: "size-4 shrink-0",
    md: "size-5 shrink-0"
  }.freeze

  # Negative margins let the 44px target sit in the padding without making the alert taller
  DISMISS_SIZES = {
    sm: "-my-2 -mr-1.5",
    md: "-my-3 -mr-2"
  }.freeze

  # A small alert's 44px × is taller than its line, so the text drops to the ×'s centre
  DISMISSIBLE_OFFSETS = {
    sm: "mt-1.5",
    md: nil
  }.freeze

  BASE = "flex items-start rounded-md border"
  DISMISS = "inline-flex size-11 shrink-0 items-center justify-center rounded-md cursor-pointer " \
            "hover:bg-current/10 focus-visible:outline-2 focus-visible:-outline-offset-2 " \
            "focus-visible:outline-focus"

  # @param tone [Symbol] :neutral, :info, :success, :warning or :danger
  # @param emphasis [Symbol] :subtle (a tinted fill) or :solid (the tone's strong fill)
  # @param size [Symbol] :sm or :md
  # @param title [String, nil] a bold first line
  # @param icon [String, nil] a {Components::Kit::IconSprite} glyph to lead with
  # @param dismissible [Boolean] show a × that removes the alert
  # @param dismiss_after [Integer, nil] milliseconds before the alert removes itself
  # @param role [Symbol, nil] :status or :alert; defaults to :alert for danger, :status otherwise
  # @param attributes [Hash] extra attributes for the root element, mixed with the alert's own
  def initialize(tone: :neutral, emphasis: :subtle, size: :md, title: nil, icon: nil,
                 dismissible: false, dismiss_after: nil, role: nil, **attributes)
    @tone = tone
    @emphasis = emphasis
    @size = size
    @title = title
    @icon = icon
    @dismissible = dismissible
    @dismiss_after = dismiss_after
    @role = role || (tone == :danger ? :alert : :status)
    @attributes = attributes
  end

  def view_template(&block)
    offset = DISMISSIBLE_OFFSETS.fetch(@size) if @dismissible
    div(**mix(root_attributes, @attributes)) do
      icon(@icon, class: [ ICON_SIZES.fetch(@size), offset ]) if @icon
      div(class: [ "min-w-0 flex-1", offset ]) do
        p(class: "font-semibold") { @title } if @title
        div { yield(self) } if block
        actions if @action_block
      end
      dismiss_button if @dismissible
    end
  end

  # Links or buttons under the message. Call it inside the alert's block.
  #
  # @yield the actions
  def action(&block)
    @action_block = block
  end

  private

  def root_attributes
    attrs = { class: [ BASE, TONES.fetch(@tone), EMPHASES.fetch(@emphasis), SIZES.fetch(@size) ], role: @role }
    attrs[:data] = { controller: "flash", flash_delay_value: @dismiss_after || 0 } if @dismissible || @dismiss_after
    attrs
  end

  def actions
    div(class: "mt-1 flex flex-wrap items-center gap-x-4 font-medium") do
      # Call, not instance_exec, so the block keeps its caller's `self`
      @action_block.call
    end
  end

  def dismiss_button
    button(type: "button", class: [ DISMISS, DISMISS_SIZES.fetch(@size) ],
           aria: { label: "Dismiss" }, data: { action: "flash#dismiss" }) do
      svg(class: ICON_SIZES.fetch(@size), viewBox: "0 0 24 24", fill: "none", stroke: "currentColor",
          stroke_width: "2", aria: { hidden: "true" }, focusable: "false") do |s|
        s.path(stroke_linecap: "round", stroke_linejoin: "round", d: "M6 18L18 6M6 6l12 12")
      end
    end
  end
end
