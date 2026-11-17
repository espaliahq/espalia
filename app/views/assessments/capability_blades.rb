# frozen_string_literal: true

# The assessment card's capabilities at a glance: a blade per capability,
# as long as the level it has reached, around a dashed circle at the
# assessed level met.
class Views::Assessments::CapabilityBlades < Views::Base
  RADIUS = 30.0
  # The share of a short blade's colour that shows through.
  SHORT_OPACITY = 0.45

  # @param shape [Assessments::CapabilityShape]
  def initialize(shape:)
    @shape = shape
  end

  def view_template
    div(class: "flex shrink-0 items-center gap-3", data: { capability_blades: true }) do
      span(class: "hidden text-right text-xs leading-tight text-muted @[22rem]:block", aria: { hidden: "true" },
           data: { blades_caption: true }) do
        span(class: "block text-sm font-bold text-default tabular-nums") { "#{met_count} of #{points.size}" }
        whitespace
        span(class: "block") { "met at #{assessed_code}" }
      end
      svg(viewBox: "#{-RADIUS} #{-RADIUS} #{RADIUS * 2} #{RADIUS * 2}", class: "block size-16 shrink-0",
          role: "img", aria: { label: "#{met_count} of #{points.size} capabilities met at #{assessed_code}" }) do |s|
        category_slots(s)
        points.each_with_index { |point, i| blade(s, point, i) if point.reached }
        s.circle(r: radius_for(@shape.assessed_index), fill: "none", stroke_width: 0.9, stroke_dasharray: "2 2",
                 class: "stroke-(--gos-content-default)", data: { blades_met: true })
      end
    end
  end

  private

  def points = @shape.points

  def assessed_code = @shape.codes[@shape.assessed_index]

  def met_count = points.count { |point| point.reached && point.reached >= @shape.assessed_index }

  def radius_for(position) = (RADIUS * @shape.fraction(position)).round(2)

  # Each category's slots, tinted as one wedge so no seam shows between them,
  # and so an unrated capability still holds its place.
  def category_slots(s)
    first = 0
    @shape.groups.each do |group|
      s.path(d: wedge(RADIUS, first, first + group.points.size),
             class: Views::Assessments::CapabilityRadar::SEGMENT.fetch(group.hue),
             data: { blades_category: group.name.to_s })
      first += group.points.size
    end
  end

  def blade(s, point, i)
    short = point.reached < @shape.assessed_index
    s.path(d: wedge(radius_for(point.reached), i, i + 1), fill_opacity: (SHORT_OPACITY if short),
           stroke_opacity: (SHORT_OPACITY if short), stroke_width: 0.5,
           class: "#{Views::Assessments::CapabilityRadar::DOT.fetch(point.hue)} " \
                  "#{Views::Assessments::CapabilityRadar::SPOKE.fetch(point.hue)}",
           data: { blade: point.number, blade_short: (true if short) })
  end

  # Degrees clockwise from twelve o'clock to where slot `i` starts.
  def start(i) = -90.0 + (i * 360.0 / points.size)

  # Slots `from` up to `to`, arced half a slot at a time so no arc passes
  # 180 degrees, even a lone capability's full circle.
  def wedge(radius, from, to)
    arcs = (from * 2...to * 2).map { |half| "A#{radius} #{radius} 0 0 1 #{xy(radius, start((half + 1) / 2.0)).join(' ')}" }
    "M0 0 L#{xy(radius, start(from)).join(' ')} #{arcs.join(' ')} Z"
  end

  def xy(radius, degrees)
    rad = degrees * Math::PI / 180
    [ (radius * Math.cos(rad)).round(2), (radius * Math.sin(rad)).round(2) ]
  end
end
