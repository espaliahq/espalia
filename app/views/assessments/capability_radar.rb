# frozen_string_literal: true

# The capability radar: a segment per category, a spoke per capability whose
# length is the level it has reached, and a ring per level. The centre is the
# first level met; the assessed level's ring is solid, the next one dashed.
#
# `:compact` is the hero's glance, drawn as a picture inside its trigger;
# `:detailed` is the capability map's, where each spoke is a link.
class Views::Assessments::CapabilityRadar < Views::Base
  # The detailed radar draws larger against the same marks, so the disc fills
  # the map's column and the badges and strokes read finer.
  RADIUS = { compact: 100.0, detailed: 150.0 }.freeze
  # The nearest a blocked sign comes to the centre, as a share of the radius,
  # so a capability with no level yet still shows its sign on its own spoke.
  MARK_FLOOR = 0.14
  # The farthest out the floor moves, however crowded the spokes.
  MARK_CEILING = 0.6

  # Written out per hue: Tailwind builds only class names it can read whole.
  SEGMENT = {
    1 => "fill-(--gos-category-1)",
    2 => "fill-(--gos-category-2)",
    3 => "fill-(--gos-category-3)",
    4 => "fill-(--gos-category-4)",
    5 => "fill-(--gos-category-5)",
    6 => "fill-(--gos-category-6)",
    7 => "fill-(--gos-category-7)",
    8 => "fill-(--gos-category-8)"
  }.freeze
  SPOKE = {
    1 => "stroke-(--gos-category-1-strong)",
    2 => "stroke-(--gos-category-2-strong)",
    3 => "stroke-(--gos-category-3-strong)",
    4 => "stroke-(--gos-category-4-strong)",
    5 => "stroke-(--gos-category-5-strong)",
    6 => "stroke-(--gos-category-6-strong)",
    7 => "stroke-(--gos-category-7-strong)",
    8 => "stroke-(--gos-category-8-strong)"
  }.freeze
  DOT = {
    1 => "fill-(--gos-category-1-strong)",
    2 => "fill-(--gos-category-2-strong)",
    3 => "fill-(--gos-category-3-strong)",
    4 => "fill-(--gos-category-4-strong)",
    5 => "fill-(--gos-category-5-strong)",
    6 => "fill-(--gos-category-6-strong)",
    7 => "fill-(--gos-category-7-strong)",
    8 => "fill-(--gos-category-8-strong)"
  }.freeze
  BADGE = {
    1 => "fill-(--gos-category-1) stroke-(--gos-category-1-strong)",
    2 => "fill-(--gos-category-2) stroke-(--gos-category-2-strong)",
    3 => "fill-(--gos-category-3) stroke-(--gos-category-3-strong)",
    4 => "fill-(--gos-category-4) stroke-(--gos-category-4-strong)",
    5 => "fill-(--gos-category-5) stroke-(--gos-category-5-strong)",
    6 => "fill-(--gos-category-6) stroke-(--gos-category-6-strong)",
    7 => "fill-(--gos-category-7) stroke-(--gos-category-7-strong)",
    8 => "fill-(--gos-category-8) stroke-(--gos-category-8-strong)"
  }.freeze
  BADGE_TEXT = {
    1 => "fill-(--gos-category-1-content)",
    2 => "fill-(--gos-category-2-content)",
    3 => "fill-(--gos-category-3-content)",
    4 => "fill-(--gos-category-4-content)",
    5 => "fill-(--gos-category-5-content)",
    6 => "fill-(--gos-category-6-content)",
    7 => "fill-(--gos-category-7-content)",
    8 => "fill-(--gos-category-8-content)"
  }.freeze
  RING_STROKE = { assessed: "stroke-(--gos-content-muted)", next: "stroke-(--gos-score-ahead)",
                  nil => "stroke-(--gos-border-default)" }.freeze
  # The least a ring label's baseline sits from another's on the same side.
  RING_LABEL_GAP = 12
  RING_LABEL = { assessed: "fill-(--gos-content-default) font-bold", next: "fill-(--gos-score-ahead) font-bold",
                 nil => "fill-(--gos-content-muted) font-medium" }.freeze

  # @param shape [Assessments::CapabilityShape]
  # @param size [Symbol] :compact or :detailed
  # @param assessed_as [String] what the assessed level's ring label calls it
  def initialize(shape:, size: :detailed, assessed_as: "you")
    @shape = shape
    @size = size
    @assessed_as = assessed_as
  end

  def view_template
    svg(viewBox: view_box, class: "block h-full w-full overflow-visible", **svg_semantics) do |s|
      @shape.groups.each { |group| segment(s, group) }
      rings(s)
      web(s)
      points.each_with_index { |point, i| spoke(s, point, i) }
      ring_labels(s) unless compact?
    end
  end

  private

  def points = @shape.points

  # The compact radar sits inside its trigger, which carries the name; the
  # detailed one is a group of links.
  def svg_semantics
    return { aria: { hidden: "true" } } if compact?

    { role: "group", aria: { label: "Capability radar: #{points.size} capabilities in #{@shape.groups.size} groups" } }
  end

  def compact? = @size == :compact

  def view_box
    pad = compact? ? 2 : 30
    edge = radius + pad
    "#{-edge} #{-edge} #{edge * 2} #{edge * 2}"
  end

  # Degrees, clockwise from twelve o'clock, at the middle of spoke `i`'s slice.
  def angle(i) = -90.0 + ((i + 0.5) * 360.0 / points.size)

  def xy(radius, degrees)
    rad = degrees * Math::PI / 180
    [ (radius * Math.cos(rad)).round(2), (radius * Math.sin(rad)).round(2) ]
  end

  def radius = RADIUS.fetch(@size)

  def radius_for(position) = radius * @shape.fraction(position)

  def segment(s, group)
    first = points.index(group.points.first)
    from = angle(first) - (180.0 / points.size)
    to = from + (group.points.size * 360.0 / points.size)
    attrs = { class: SEGMENT.fetch(group.hue), data: { radar_segment: group.name.to_s } }
    return s.circle(r: radius, **attrs) if group.points.size == points.size

    x0, y0 = xy(radius, from)
    x1, y1 = xy(radius, to)
    large = to - from > 180 ? 1 : 0
    s.path(d: "M0 0 L#{x0} #{y0} A#{radius} #{radius} 0 #{large} 1 #{x1} #{y1} Z", **attrs)
  end

  def rings(s)
    @shape.codes.each_with_index.drop(1).each do |code, i|
      role = ring_role(i)
      s.circle(r: radius_for(i).round(2), fill: "none", stroke_width: role ? 1.5 : 0.75,
               stroke_dasharray: role == :next ? "5 4" : nil,
               class: RING_STROKE.fetch(role),
               data: { radar_ring: code, radar_ring_role: role })
    end
  end

  # Up the top of the radar, haloed so they read across spokes and segments.
  # The rim's label sits inside it, clear of the number badges. Rings too close
  # to label apart keep the assessed and next labels (one moves left of the
  # spoke) and drop the plain ones.
  def ring_labels(s)
    placed = []
    ring_label_candidates.each do |label|
      clashes = ->(side) { placed.any? { |p| p[:side] == side && (p[:y] - label[:y]).abs < RING_LABEL_GAP } }
      next unless (side = [ :right, (:left if label[:role]) ].compact.find { |option| !clashes.(option) })

      placed << label.merge(side: side)
    end
    placed.sort_by { |label| label[:index] }.each do |label|
      s.text(x: label[:side] == :left ? -4 : 4, y: label[:y].round(2), font_size: 10,
             text_anchor: ("end" if label[:side] == :left),
             class: "#{RING_LABEL.fetch(label[:role])} stroke-(--gos-surface-overlay) [paint-order:stroke] " \
                    "[stroke-width:3px] [stroke-linejoin:round]",
             data: { radar_ring_label: label[:code] }) { [ label[:code], ring_suffix(label[:role]) ].compact.join(" · ") }
    end
  end

  # The assessed and next rings' labels first, so they win any clash.
  def ring_label_candidates
    @shape.codes.each_with_index.drop(1).map do |code, i|
      { code: code, index: i, role: ring_role(i),
        y: i == @shape.codes.size - 1 ? -radius_for(i) + 11 : -(radius_for(i) + 3) }
    end.partition { |label| label[:role] }.flatten
  end

  def ring_suffix(role) = { assessed: @assessed_as, next: "next" }[role]

  def ring_role(index)
    return :assessed if index == @shape.assessed_index
    :next if index == @shape.assessed_index + 1
  end

  # The web joins the capabilities that have a level; an unrated one has none.
  def web(s)
    corners = points.each_with_index.filter_map do |point, i|
      xy(radius_for(point.reached), angle(i)).join(",") if point.reached
    end
    return if corners.size < 2

    s.polygon(points: corners.join(" "), fill_opacity: 0.07, stroke_opacity: 0.55, stroke_width: 1.25,
              stroke_linejoin: "round", class: "fill-(--gos-content-default) stroke-(--gos-content-default)")
  end

  def spoke(s, point, i)
    return spoke_marks(s, point, i) if compact?

    s.a(href: "#cell-#{point.stable_id}-#{@shape.person_level}",
        class: "group/spoke cursor-pointer outline-hidden",
        aria: { label: spoke_name(point) },
        data: { radar_spoke: point.number, capability_map_key: point.number, refresh_focus: "spoke-#{point.number}",
                turbo_frame: "_top", controller: "continue-assessing",
                action: "click->modal#close click->continue-assessing#focus",
                continue_assessing_capability_stable_id_value: point.stable_id,
                continue_assessing_level_ordinal_value: @shape.person_level,
                continue_assessing_focus_card_value: true }) do
      hit_x, hit_y = xy(radius + 26, angle(i))
      s.line(x1: 0, y1: 0, x2: hit_x, y2: hit_y, stroke: "transparent", stroke_width: 18)
      rim_x, rim_y = xy(radius, angle(i))
      s.line(x1: 0, y1: 0, x2: rim_x, y2: rim_y, stroke_width: 1, stroke_opacity: 0.25, class: SPOKE.fetch(point.hue))
      spoke_marks(s, point, i)
      number_badge(s, point, i)
    end
  end

  def spoke_marks(s, point, i)
    s.g(data: (compact? ? { radar_spoke: point.number } : {})) do
      if point.reached
        x, y = xy(radius_for(point.reached), angle(i))
        s.line(x1: 0, y1: 0, x2: x, y2: y, stroke_width: compact? ? 2.5 : 3, stroke_linecap: "round",
               class: "#{SPOKE.fetch(point.hue)} group-hover/spoke:stroke-[5] group-focus-visible/spoke:stroke-[5] " \
                      "group-data-[hot=true]/spoke:stroke-[5]")
        s.circle(cx: x, cy: y, r: compact? ? 0 : 4, class: DOT.fetch(point.hue))
      end
      blocked_marker(s, *xy([ point.reached ? radius_for(point.reached) : 0, mark_floor ].max, angle(i))) if point.blocked
    end
  end

  # Signs on spokes shorter than this would overlap their neighbours', so they
  # sit here instead, where adjacent spokes are a sign's diagonal (plus a gap)
  # apart: two squares side by side on a slant clear each other only there.
  def mark_floor
    @mark_floor ||= begin
      clearance = (marker_half * 2 * Math.sqrt(2)) + 2
      apart = points.size > 1 ? clearance / (2 * Math.sin(Math::PI / points.size)) : 0
      apart.clamp(radius * MARK_FLOOR, radius * MARK_CEILING)
    end
  end

  def marker_half = compact? ? 6 : 8

  def spoke_name(point)
    held = (point.required ? ". Required, blocks the score" : ". Blocks the score") if point.blocked
    "#{point.number}. #{point.name}, #{point.label}#{held}. Open the capability"
  end

  # A capability whose gap blocks the score: a sign as well as a colour.
  def blocked_marker(s, x, y)
    half = marker_half
    s.g(transform: "translate(#{x} #{y})", data: { radar_blocked: true }) do
      s.rect(x: -half, y: -half, width: half * 2, height: half * 2, rx: half / 2.0, stroke_width: 1.5,
             class: "fill-(--gos-warning-strong) stroke-(--gos-surface-overlay)")
      s.text(y: (half / 2.0).round(1), text_anchor: "middle", font_size: half * 1.4, font_weight: 800,
             class: "fill-(--gos-warning-content-inverse)") { "!" }
    end
  end

  # The number the capability's lane carries too, so a spoke can be found in the list.
  def number_badge(s, point, i)
    x, y = xy(radius + 16, angle(i))
    s.circle(cx: x, cy: y, r: 11, stroke_width: 1,
             class: "#{BADGE.fetch(point.hue)} group-hover/spoke:stroke-(--gos-focus-ring) " \
                    "group-focus-visible/spoke:stroke-(--gos-focus-ring) group-focus-visible/spoke:stroke-2")
    s.text(x: x, y: (y + 4).round(2), text_anchor: "middle", font_size: 11, font_weight: 700,
           class: BADGE_TEXT.fetch(point.hue)) { point.number.to_s }
  end
end
