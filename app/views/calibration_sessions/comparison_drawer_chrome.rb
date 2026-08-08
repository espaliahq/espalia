# frozen_string_literal: true

# The comparison drawer's shared shell — the sticky bottom shelf both
# calibration comparison surfaces (the session page's cohort face, the
# drill-in's capability face) render their person cards into, so the two
# screens hold people side by side the exact same way.
#
# Fixed to the viewport bottom, full width — the main pane and the session
# log both stay visible above it. Renders nothing while unoccupied. The
# host page wrapper must carry
# `has-[#calibration-comparison-drawer]:pb-[45vh]` so page-end content can
# scroll clear of the fixed shelf.
module Views::CalibrationSessions::ComparisonDrawerChrome
  # @param pin_count [Integer] occupied pin slots
  # @param max_pins [Integer]
  # @yield renders the card row's contents
  def comparison_drawer_chrome(pin_count:, max_pins:)
    div(
      class: "fixed inset-x-0 bottom-0 z-30 border-t-2 border-violet-500 " \
             "bg-gray-50 dark:bg-gray-900 px-4 sm:px-6 pb-3 pt-2",
      id: "calibration-comparison-drawer",
      data: { controller: "comparison-drawer" }
    ) do
      div(class: "flex items-center justify-between gap-2") do
        p(class: "text-xs font-semibold uppercase tracking-wide text-gray-600 dark:text-gray-300") do
          plain "Comparison"
          if pin_count.positive?
            span(class: "ml-2 font-medium normal-case tracking-normal text-violet-700 dark:text-violet-300") do
              "#{pin_count} pinned · #{max_pins - pin_count} free"
            end
          end
        end
        button(
          type: "button",
          class: "inline-flex min-h-11 items-center px-2 text-xs font-medium " \
                 "text-gray-600 dark:text-gray-300 hover:underline",
          data: { action: "comparison-drawer#toggle", comparison_drawer_target: "label" },
          aria: { expanded: "true", controls: "comparison-drawer-body" }
        ) { "Collapse" }
      end
      div(
        id: "comparison-drawer-body",
        class: "mt-1 flex items-start gap-4 overflow-x-auto pb-1",
        data: { comparison_drawer_target: "body" }
      ) do
        yield
      end
    end
  end
end
