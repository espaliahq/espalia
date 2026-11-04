# frozen_string_literal: true

# A dot in the brand colour saying something needs the viewer, with words for
# a screen reader. The edge in brand text colour carries the 3:1 a graphic
# needs where a light brand fill (Bento's lime, Default's teal) on a light
# surface doesn't.
class Components::Kit::AttentionDot < Components::Base
  CLASSES = "inline-block size-2 shrink-0 rounded-full bg-brand-strong text-brand ring-1 ring-current"

  # @param label [String] what a screen reader hears, e.g. "needs your attention"
  # @param attrs [Hash] merged onto the dot
  def initialize(label, **attrs)
    @label = label
    @attrs = attrs
  end

  def view_template
    span(**mix({ class: CLASSES, aria: { hidden: "true" }, data: { mark: true } }, @attrs))
    span(class: "sr-only") { " (#{@label})" }
  end
end
