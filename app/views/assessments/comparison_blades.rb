# frozen_string_literal: true

# The comparison tab's blades: the card's blades drawn large, with a line
# across each blade at the group's middle score, on the same scale.
class Views::Assessments::ComparisonBlades < Views::Assessments::CapabilityBlades
  # The share of a slot the group's line leaves clear at each end.
  LINE_INSET = 0.12
  LINE_WIDTH = 1.1

  # @param shape [Assessments::CapabilityShape] the person's, read at the compared level
  # @param medians [Hash{String => Float}] stable_id => the group's middle score, 1.0 the level met
  # @param label [String] the picture's accessible name
  def initialize(shape:, medians:, label:)
    super(shape:)
    @medians = medians
    @label = label
  end

  def view_template
    svg(viewBox: "#{-RADIUS} #{-RADIUS} #{RADIUS * 2} #{RADIUS * 2}", class: "mx-auto block aspect-square w-full max-w-sm",
        role: "img", aria: { label: @label }) do |s|
      category_slots(s)
      points.each_with_index { |point, i| beyond(s, point, i) if ahead?(point) }
      points.each_with_index { |point, i| blade(s, point, i) if point.reached }
      s.circle(r: MET_RADIUS, fill: "none", stroke_width: 0.4, stroke_dasharray: "1 1",
               class: "stroke-(--gos-content-muted)", data: { blades_met: true })
      points.each_with_index { |point, i| median_line(s, point, i) }
    end
  end

  private

  def median_line(s, point, i)
    median = @medians[point.stable_id]
    return unless median

    radius = radius_for(@shape.assessed_index - 1 + median)
    return if radius.zero?

    # An edge in the modal's surface, on the outer side only, lifts the line off a blade of any category colour.
    s.path(d: arc(radius + LINE_WIDTH / 2, i), fill: "none", stroke_width: LINE_WIDTH, stroke_linecap: "butt",
           class: "stroke-(--gos-surface-overlay)")
    s.path(d: arc(radius, i), fill: "none", stroke_width: LINE_WIDTH, stroke_linecap: "round",
           class: "stroke-(--gos-accent-strong)", data: { blade_median: point.number })
  end

  def arc(radius, i)
    from = xy(radius, start(i + LINE_INSET))
    to = xy(radius, start(i + 1 - LINE_INSET))
    "M#{from.join(' ')} A#{radius} #{radius} 0 0 1 #{to.join(' ')}"
  end
end
