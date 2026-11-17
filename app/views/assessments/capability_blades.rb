# frozen_string_literal: true

# A person's capabilities at a glance, for the assessment card: a blade per
# capability, clockwise from the top and coloured by category, whose length
# is the level it has reached. The blades touch, so the category colours
# separate them. The dashed circle is the assessed level met; a blade short
# of it is faded.
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
      span(class: "hidden text-right text-xs leading-tight text-muted @[19rem]:block", aria: { hidden: "true" },
           data: { blades_caption: true }) do
        span(class: "block text-sm font-bold text-default tabular-nums") { "#{met_count} of #{points.size}" }
        whitespace
        span(class: "block") { "met at #{assessed_code}" }
      end
      svg(viewBox: "#{-RADIUS} #{-RADIUS} #{RADIUS * 2} #{RADIUS * 2}", class: "block size-16 shrink-0",
          role: "img", aria: { label: "#{met_count} of #{points.size} capabilities met at #{assessed_code}" }) do |s|
        points.each_with_index { |point, i| slot(s, point, i) }
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

  # The whole slot, tinted, so an unrated capability still holds its place.
  def slot(s, point, i)
    s.path(d: wedge(RADIUS, i), class: Views::Assessments::CapabilityRadar::SEGMENT.fetch(point.hue))
  end

  def blade(s, point, i)
    short = point.reached < @shape.assessed_index
    s.path(d: wedge(radius_for(point.reached), i), fill_opacity: (SHORT_OPACITY if short),
           class: Views::Assessments::CapabilityRadar::DOT.fetch(point.hue),
           data: { blade: point.number, blade_short: (true if short) })
  end

  # Degrees clockwise from twelve o'clock to where slot `i` starts.
  def start(i) = -90.0 + (i * 360.0 / points.size)

  # Arced through the slot's middle, so a lone capability's full circle draws too.
  def wedge(radius, i)
    arc = ->(degrees) { "A#{radius} #{radius} 0 0 1 #{xy(radius, degrees).join(' ')}" }
    "M0 0 L#{xy(radius, start(i)).join(' ')} #{arc.(start(i + 0.5))} #{arc.(start(i + 1))} Z"
  end

  def xy(radius, degrees)
    rad = degrees * Math::PI / 180
    [ (radius * Math.cos(rad)).round(2), (radius * Math.sin(rad)).round(2) ]
  end
end
