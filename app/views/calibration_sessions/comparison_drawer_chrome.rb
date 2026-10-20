# frozen_string_literal: true

# The comparison drawer's shared shell — the sticky bottom shelf both
# calibration comparison surfaces (the session page's level face, the
# drill-in's capability face) render their person cards into, so the two
# screens hold people side by side the exact same way.
#
# Fixed to the viewport bottom, full width — the main pane and the session
# log both stay visible above it. Renders nothing while unoccupied. The
# host page wrapper must carry `data-drawer-host` —
# `comparison_drawer_controller` pads it by the drawer's measured height
# (applied on connect, so it survives Turbo Frame swaps) so page-end
# content can scroll clear of the fixed shelf.
module Views::CalibrationSessions::ComparisonDrawerChrome
  # The drawer holds at most this many people (inspector + pins) — the
  # deliberate juxtaposition is 2–3 cards, not a dashboard.
  MAX_PINS = 3

  # The drawer's default card-row height; drag the handle to resize.
  DEFAULT_HEIGHT = "38vh"

  # @param pin_count [Integer] occupied pin slots
  # @param max_pins [Integer]
  # @yield renders the card row's contents
  #
  # No header row — the shelf is self-evidently the comparison, so every
  # vertical pixel goes to the cards. The controls float on the top edge:
  # a full-width drag handle (resize; dragging within 20px of the viewport
  # bottom collapses) and a ✕ that collapses to a slim expand bar.
  def comparison_drawer_chrome(pin_count:, max_pins:)
    div(
      class: "fixed inset-x-0 bottom-0 z-30 border-t-2 border-compared " \
             "bg-page px-4 sm:px-6 pb-2",
      id: "calibration-comparison-drawer",
      data: { controller: "comparison-drawer" }
    ) do
      # Drag handle: sits ON the border, holds no layout height.
      div(
        class: "absolute inset-x-0 -top-2 h-4 cursor-row-resize touch-none flex items-center justify-center",
        # Focusable separator: arrows resize from the keyboard; the
        # controller keeps aria-value* honest across pointer/keys/viewport.
        tabindex: "0",
        data: { action: "pointerdown->comparison-drawer#resizeStart " \
                        "keydown->comparison-drawer#resizeKey",
                comparison_drawer_target: "handle" },
        role: "separator",
        aria: { orientation: "horizontal", label: "Resize the comparison drawer",
                controls: "comparison-drawer-body" }
      ) do
        span(class: "h-1 w-12 rounded-full bg-compared", aria: { hidden: "true" })
      end
      # Collapse ✕: floats above the top edge, costs no card space.
      button(
        type: "button",
        class: "absolute right-4 -top-4 z-10 inline-flex h-8 w-8 items-center justify-center " \
               "rounded-full border border-emphasized bg-default " \
               "text-base text-muted shadow-lifted hover:bg-default-hover",
        data: { action: "comparison-drawer#toggle", comparison_drawer_target: "collapse" },
        aria: { expanded: "true", controls: "comparison-drawer-body",
                label: "Collapse the comparison drawer" }
      ) { "×" }
      # Collapsed state: a slim expand bar carrying the count (revealed by
      # the controller; the drawer opens expanded by default).
      button(
        type: "button",
        class: "hidden w-full min-h-8 items-center justify-center gap-2 text-xs font-semibold " \
               "uppercase tracking-wide text-muted hover:text-compared",
        data: { action: "comparison-drawer#toggle", comparison_drawer_target: "expandBar" },
        aria: { expanded: "false", controls: "comparison-drawer-body" }
      ) do
        plain "Comparison · #{pin_count} pinned · #{max_pins - pin_count} free — expand"
      end
      div(
        id: "comparison-drawer-body",
        class: "mt-2 flex items-stretch gap-4 overflow-x-auto overflow-y-hidden pb-1",
        style: "height: #{DEFAULT_HEIGHT}",
        data: { comparison_drawer_target: "body" }
      ) do
        yield
      end
    end
  end
end
