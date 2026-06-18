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
    lg: "max-w-lg"
  }.freeze

  # @param id [String] DOM id for the dialog overlay
  # @param title [String] heading text
  # @param size [Symbol] :sm, :md, or :lg
  # @param standalone [Boolean] render an own `modal` controller + trigger slot
  # @param dismiss_on_outside_click [Boolean] allow a background click to close
  #   the modal. Defaults to false so transactional modals (those holding
  #   unsaved input) can't be discarded by accident — they close via the ×
  #   button, Cancel, Esc, or a successful submit. Set true only for purely
  #   informational modals. (Embedded modals — `standalone: false` — read this
  #   value from the host element carrying `data-controller="modal"` instead.)
  def initialize(id:, title:, size: :md, standalone: true, dismiss_on_outside_click: false)
    @id = id
    @title = title
    @size = size
    @standalone = standalone
    @dismiss_on_outside_click = dismiss_on_outside_click
  end

  def view_template(&block)
    if @standalone
      div(class: "relative inline-block text-left",
          data: { controller: "modal", action: "keydown.esc@window->modal#close",
                  modal_dismiss_on_outside_click_value: @dismiss_on_outside_click.to_s }) do
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
  def trigger(&block)
    button(
      type: "button",
      data: { action: "modal#open" },
      class: "inline-flex items-center text-sm font-medium px-3 py-1.5 rounded-md " \
             "border border-gray-300 dark:border-gray-600 text-gray-700 dark:text-gray-200 " \
             "hover:bg-gray-50 dark:hover:bg-gray-800 cursor-pointer"
    ) { yield }
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
      data: { modal_target: "overlay" },
      class: "fixed inset-0 z-40 hidden items-center justify-center bg-black/40 px-4",
      role: "dialog",
      aria_modal: "true",
      aria_labelledby: "#{@id}-title"
    ) do
      div(
        class: "w-full #{SIZES[@size]} rounded-lg bg-white dark:bg-gray-900 p-5 shadow-xl",
        data: { modal_target: "panel" }
      ) do
        header
        # Call (don't instance_exec) so the block keeps its caller's `self` —
        # the body usually calls methods/ivars on the view that rendered the
        # modal. Phlex shares the output buffer, so it still emits in position.
        @body_block&.call
      end
    end
  end

  def header
    div(class: "flex items-baseline justify-between mb-3") do
      h2(id: "#{@id}-title",
         class: "text-lg font-semibold text-gray-900 dark:text-white") { @title }
      button(
        type: "button",
        class: "text-gray-400 hover:text-gray-600 dark:hover:text-gray-200 text-xl leading-none cursor-pointer",
        data: { action: "click->modal#close" },
        aria: { label: "Close" }
      ) { "×" }
    end
  end
end
