# frozen_string_literal: true

# Reusable modal/dialog component powered by the `modal` Stimulus controller
# (open/close, Esc-to-close, click-outside, body-scroll-lock).
#
# Two modes:
#
# * **Standalone** (default) — the component renders its own
#   `data-controller="modal"` element wrapping an optional `trigger` slot and
#   the dialog. Use when the button that opens the modal sits right next to it.
#
#     render Components::Kit::Modal.new(id: "delegate-modal", title: "Delegates") do |m|
#       m.trigger { "Delegates" }
#       m.body { … }
#     end
#
# * **Embedded** (`standalone: false`) — renders only the dialog overlay/panel
#   (with `modal` targets) and relies on an ancestor element carrying
#   `data-controller="modal"`. Use when many remote triggers across the page
#   open one shared modal (e.g. the evidence "+ Add" buttons on every cell).
#   Remote triggers fire `data-action="click->modal#open"`; the controller
#   dispatches a window `modal:open` event so a sibling feature controller can
#   prefill the form.
#
class Components::Kit::Modal < Components::Base
  SIZES = {
    sm: "max-w-sm",
    md: "max-w-md",
    lg: "max-w-lg",
    xl: "max-w-xl",
    "2xl": "max-w-2xl",
    "3xl": "max-w-3xl"
  }.freeze

  # @param id [String] DOM id for the dialog overlay
  # @param title [String] heading text
  # @param size [Symbol] :sm, :md, :lg, :xl, :"2xl" or :"3xl"
  # @param header [Boolean] false drops the title bar and the panel's padding, for a body that
  #   draws its own heading and ×; the title still names the dialog
  # @param standalone [Boolean] render an own `modal` controller + trigger slot
  # @param dismiss_on_outside_click [Boolean] allow a background click to close
  #   the modal. Defaults to false so transactional modals (those holding
  #   unsaved input) can't be discarded by accident — they close via the ×
  #   button, Cancel, Esc, or a successful submit. Set true only for purely
  #   informational modals. (Embedded modals — `standalone: false` — read this
  #   value from the host element carrying `data-controller="modal"` instead.)
  # @param dirty_guard [String, nil] confirm message shown before Esc discards
  #   typed-but-unsaved input; nil leaves Esc immediate (audit issue #315).
  # @param panel_data [Hash] extra data attributes for the panel, for controllers that must wrap the whole body
  def initialize(id:, title:, size: :md, header: true, standalone: true, dismiss_on_outside_click: false,
                 dirty_guard: nil, panel_data: {})
    @id = id
    @title = title
    @size = size
    @header = header
    @standalone = standalone
    @dismiss_on_outside_click = dismiss_on_outside_click
    @dirty_guard = dirty_guard
    @panel_data = panel_data
  end

  def view_template(&block)
    if @standalone
      div(class: "relative inline-block text-left",
          data: { controller: "modal", action: "keydown.esc@window->modal#escape",
                  modal_dismiss_on_outside_click_value: (@dismiss_on_outside_click ? "true" : "false") }) do
        yield(self)
        dialog
      end
    else
      @body_block = nil
      yield(self)
      dialog
    end
  end

  # Standalone-only: the button that opens this modal.
  #
  # @yield trigger button content
  def trigger(&)
    render Components::Kit::Button.new(variant: :outline, size: :sm, data: { action: "modal#open" }), &
  end

  # The dialog body content.
  #
  # @yield body content
  def body(&block)
    @body_block = block
  end

  private

  def dialog
    div(
      id: @id,
      data: { modal_target: "overlay", modal_dirty_guard: @dirty_guard }.compact,
      class: "fixed inset-0 z-40 hidden items-center justify-center bg-scrim px-4",
      role: "dialog",
      aria_modal: "true",
      **(@header ? { aria_labelledby: "#{@id}-title" } : { aria_label: @title })
    ) do
      # A modal taller than the viewport used to centre and clip its own
      # header — on a phone the title and the × went off the top edge, and
      # the only way out was Esc, which nothing on screen mentioned. The
      # panel is now capped at the viewport with the header pinned and the
      # body scrolling under it, so the way out is always visible.
      div(
        class: [ "w-full max-h-[90dvh] flex flex-col rounded-lg border border-default bg-overlay shadow-2xl outline-hidden",
                 SIZES.fetch(@size), ("p-5" if @header) ],
        tabindex: "-1",
        data: { **@panel_data, modal_target: "panel" }
      ) do
        header if @header
        div(class: "min-h-0 overflow-y-auto") do
          # Call (don't instance_exec) so the block keeps its caller's `self` —
          # the body usually calls methods/ivars on the view that rendered the
          # modal. Phlex shares the output buffer, so it still emits in position.
          @body_block&.call
        end
      end
    end
  end

  def header
    div(class: "flex items-baseline justify-between mb-3 shrink-0") do
      h2(id: "#{@id}-title",
         class: "text-lg font-semibold text-default") { @title }
      button(
        type: "button",
        class: "text-muted hover:text-default text-xl leading-none cursor-pointer",
        data: { action: "click->modal#close" },
        aria: { label: "Close" }
      ) { "×" }
    end
  end
end
