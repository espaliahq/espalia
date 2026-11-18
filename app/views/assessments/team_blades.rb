# frozen_string_literal: true

# A team's blades: a blade per capability as long as the team's mean score
# against each person's own level, drawn as a card's blades are, so the
# dashed circle is the team meeting it on average.
class Views::Assessments::TeamBlades < Views::Assessments::CapabilityBlades
  # A team has no ladder of its own, so its blades read on a one-level scale.
  Shape = Data.define(:points, :groups) do
    def codes = [ nil, nil ]

    def assessed_index = 1
  end
  Point = Data.define(:number, :stable_id, :hue, :reached)
  Group = Data.define(:name, :hue, :points)

  # @param capabilities [Array<Hash>] `Operations::Assessments::TeamCapabilities`'s capabilities
  # @param label [String] the picture's accessible name
  # @param size [String] the svg's sizing classes
  def initialize(capabilities:, label:, size: "w-24")
    super(shape: shape_for(capabilities))
    @label = label
    @size = size
  end

  def view_template
    svg(viewBox: "#{-RADIUS} #{-RADIUS} #{RADIUS * 2} #{RADIUS * 2}", class: "block aspect-square h-auto #{@size}",
        role: "img", aria: { label: @label }, data: { team_blades: true }) do |s|
      category_slots(s)
      points.each_with_index { |point, i| beyond(s, point, i) if ahead?(point) }
      points.each_with_index { |point, i| blade(s, point, i) if point.reached }
      s.circle(r: MET_RADIUS, fill: "none", stroke_width: 0.9, stroke_dasharray: "2 2",
               class: "stroke-(--gos-content-default)", data: { blades_met: true })
    end
  end

  private

  def shape_for(capabilities)
    points = capabilities.each_with_index.map do |capability, i|
      Point.new(number: i + 1, stable_id: capability[:stable_id], hue: capability[:hue],
                reached: capability[:score] && capability[:score] / 100.0)
    end
    groups = points.zip(capabilities).chunk_while { |(_, a), (_, b)| a[:category_id] == b[:category_id] }
      .map { |pairs| Group.new(name: pairs.first.last[:category_name], hue: pairs.first.first.hue, points: pairs.map(&:first)) }
    Shape.new(points:, groups:)
  end
end
