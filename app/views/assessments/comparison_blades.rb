# frozen_string_literal: true

# The comparison tab's blades: the card's blades drawn large, with a line
# across each blade at the group's median, on the same scale.
class Views::Assessments::ComparisonBlades < Views::Assessments::CapabilityBlades
  # @param shape [Assessments::CapabilityShape] the person's, read at the compared level
  # @param medians [Hash{String => Float}] stable_id => the group's median, 1.0 the level met
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

    s.path(d: "M#{xy(radius, start(i)).join(' ')} #{arcs(radius, i, i + 1)}", fill: "none", stroke_width: 1.1,
           class: "stroke-(--gos-accent-strong)", data: { blade_median: point.number })
  end
end
