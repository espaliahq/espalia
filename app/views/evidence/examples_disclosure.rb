# frozen_string_literal: true

# The collapsible "Examples (N)" list of role illustrations — native
# `<details>`, no JS.
#
# Extracted from the evidence modal so every surface that shows
# illustrations alongside a behavioural expectation collapses them the
# same way: the expectation is what people are rated against and stays
# in view, the examples are reference material one click away.
module Views::Evidence::ExamplesDisclosure
  # @param list [Array<String>] illustration texts
  # @param css [String] size/colour classes for each item
  # @param open [Boolean] render expanded (the entry-point row does)
  def examples_disclosure(list, css: "text-xs", open: false)
    details(class: "group", open: open) do
      summary(class: "cursor-pointer select-none text-xs font-semibold uppercase tracking-wide text-muted " \
                     "marker:content-none flex items-center gap-1") do
        span(class: "transition-transform group-open:rotate-90", aria: { hidden: "true" }) { "▸" }
        span { "Examples (#{list.size})" }
      end
      ul(class: "mt-1 space-y-1") do
        list.each do |text|
          li(class: "flex gap-2 #{css} text-muted") do
            span(class: "text-subtle", aria: { hidden: "true" }) { "•" }
            span { text }
          end
        end
      end
    end
  end
end
