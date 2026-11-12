# frozen_string_literal: true

# A chip: a toggle that filters or picks (`aria-pressed`), or a removable chip for something
# chosen, such as a person. Selected chips take the neutral fill and a heavier weight, never
# brand (#543), so a Stimulus controller only has to flip `aria-pressed`.
#
# @example A toggle
#   render Components::Kit::Chip.new("This cycle", pressed: true, data: { action: "filter#toggle" })
#
# @example Removable
#   render Components::Kit::Chip.new(person.name, remove: { data: { action: "picker#remove" } })
class Components::Kit::Chip < Components::Base
  TOGGLE = "inline-flex shrink-0 items-center gap-1.5 rounded-full border " \
           "whitespace-nowrap cursor-pointer select-none transition-colors " \
           "border-default bg-default text-default font-medium " \
           "enabled:hover:border-emphasized enabled:hover:bg-default-hover " \
           "aria-pressed:border-transparent aria-pressed:bg-neutral-muted aria-pressed:font-semibold " \
           "enabled:aria-pressed:hover:border-strong enabled:aria-pressed:hover:bg-neutral-muted " \
           "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus " \
           "disabled:cursor-not-allowed disabled:border-disabled disabled:text-disabled " \
           "disabled:aria-pressed:border-emphasized disabled:aria-pressed:bg-default"

  # `:sm` fits a dense row, such as level headings over a scale, and keeps the 24px floor.
  TOGGLE_SIZES = { md: "min-h-8 px-3 text-[13px]", sm: "min-h-6 px-1 text-xs" }.freeze

  REMOVABLE = "inline-flex min-h-8 shrink-0 items-center gap-1.5 rounded-full border border-default " \
              "bg-neutral-subtle pr-1 pl-3 text-[13px] font-medium whitespace-nowrap text-default"

  # The × is 24px to the eye; its ::after stretches the hit area to 44px.
  REMOVE = "relative grid size-6 shrink-0 place-items-center rounded-full text-muted cursor-pointer " \
           "after:absolute after:-inset-2.5 after:content-[''] " \
           "hover:bg-neutral-muted hover:text-default " \
           "focus-visible:outline-2 focus-visible:outline-offset-0 focus-visible:outline-focus " \
           "disabled:cursor-not-allowed disabled:text-disabled disabled:hover:bg-transparent"

  # @param label [String] the chip text, and the × button's accessible name ("Remove …")
  # @param pressed [Boolean] a toggle's selected state
  # @param remove [Hash, nil] attributes for the × button; given, the chip is removable, not a toggle
  # @param remove_label [String, nil] the × button's accessible name, when "Remove <label>" won't do
  # @param disabled [Boolean]
  # @param leading_icon [String, Symbol, nil] a sprite icon before the label
  # @param size [Symbol] a toggle's size, `:md` or `:sm`
  # @param attrs [Hash] passed through to the chip; `class:` is appended
  def initialize(label, pressed: false, remove: nil, remove_label: nil, disabled: false, leading_icon: nil, size: :md,
                 **attrs)
    @label = label
    @size = size
    @pressed = pressed
    @remove = remove
    @remove_label = remove_label || "Remove #{label}"
    @disabled = disabled
    @leading_icon = leading_icon
    @attrs = attrs
  end

  def view_template
    @remove ? removable : toggle
  end

  private

  def toggle
    button(**@attrs, type: :button, disabled: @disabled, aria: { **@attrs.fetch(:aria, {}), pressed: @pressed.to_s },
           class: classes("#{TOGGLE} #{TOGGLE_SIZES.fetch(@size)}")) do
      leading_icon
      plain @label
    end
  end

  def removable
    span(**@attrs, class: classes(REMOVABLE)) do
      leading_icon
      plain @label
      button(**@remove, type: :button, disabled: @disabled,
             aria: { **@remove.fetch(:aria, {}), label: @remove_label }, class: REMOVE) do
        svg(viewBox: "0 0 16 16", fill: "none", stroke: "currentColor", stroke_width: "2", stroke_linecap: "round",
            class: "size-3", aria: { hidden: "true" }, focusable: "false") { |s| s.path(d: "M4 4l8 8M12 4l-8 8") }
      end
    end
  end

  def leading_icon
    icon(@leading_icon, class: "size-3.5 shrink-0") if @leading_icon
  end

  def classes(base) = [ base, @attrs[:class] ].compact.join(" ")
end
