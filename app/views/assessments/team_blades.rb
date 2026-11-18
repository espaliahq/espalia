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
  # A group score of 0 still draws, just off the centre, so it can't read as no comparison.
  ZERO_MEDIAN_RADIUS = 1.5

  # @param capabilities [Array<Hash>] `Operations::Assessments::TeamCapabilities`'s capabilities
  # @param label [String] the picture's accessible name
  # @param size [String] the svg's sizing classes
  # @param medians [Boolean] draw a line across each blade at its `group_median`
  def initialize(capabilities:, label:, size: "w-24", medians: false)
    super(shape: shape_for(capabilities))
    @capabilities = capabilities
    @label = label
    @size = size
    @medians = medians
  end

  def view_template
    svg(viewBox: "#{-RADIUS} #{-RADIUS} #{RADIUS * 2} #{RADIUS * 2}", class: "block aspect-square h-auto #{@size}",
        role: "img", aria: { label: @label }, data: { team_blades: true }) do |s|
      category_slots(s)
      points.each_with_index { |point, i| beyond(s, point, i) if ahead?(point) }
      points.each_with_index { |point, i| blade(s, point, i) if point.reached }
      s.circle(r: MET_RADIUS, fill: "none", stroke_width: 0.9, stroke_dasharray: "2 2",
               class: "stroke-(--gos-content-default)", data: { blades_met: true })
      @capabilities.each_with_index { |capability, i| median_line(s, capability, i) } if @medians
    end
  end

  private

  # Past met, the rim is the highest score drawn, at least 200%, so a score
  # above 200% still reads apart from one at 200%.
  def radius_for(position)
    beyond = ((position - 1) / (top - 1)).clamp(0, 1)
    (MET_RADIUS * position.clamp(0, 1) + (RADIUS - MET_RADIUS) * beyond).round(2)
  end

  def top
    @top ||= [ 2.0, *@capabilities.flat_map { |c| [ c[:score], (c[:group_median] if @medians) ] }.compact.map { |p| p / 100.0 } ].max
  end

  # The comparison tab's line, at the group's score on the same scale.
  def median_line(s, capability, i)
    return unless capability[:group_median]

    radius = capability[:group_median].zero? ? ZERO_MEDIAN_RADIUS : radius_for(capability[:group_median] / 100.0)
    s.path(d: "M#{xy(radius, start(i)).join(' ')} #{arcs(radius, i, i + 1)}", fill: "none", stroke_width: 1.1,
           class: "stroke-(--gos-accent-strong)", data: { blade_median: i + 1 })
  end

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
