# frozen_string_literal: true

# The capability map: the radar for the shape at a glance, beside one lane per
# capability for exactly where each one stands on the ladder. A spoke and its
# lane share a number, and pointing at either lights both.
#
# Root-mounted like the score explainer, so the hero's trigger can sit inside
# a frame that reloads on every rating without closing an open map. Each
# rating streams fresh contents into `CONTENT_ID`, never a new overlay, so an
# open map stays open (`Assessments::TurboStreamHelpers`).
class Views::Assessments::CapabilityMapModal < Views::Base
  include Views::Assessments::Concerns::ScoreScale

  ID = "capability-map-modal"
  CONTENT_ID = "capability-map-content"

  FILL = {
    1 => "bg-(--gos-category-1-strong)", 2 => "bg-(--gos-category-2-strong)",
    3 => "bg-(--gos-category-3-strong)", 4 => "bg-(--gos-category-4-strong)",
    5 => "bg-(--gos-category-5-strong)", 6 => "bg-(--gos-category-6-strong)",
    7 => "bg-(--gos-category-7-strong)", 8 => "bg-(--gos-category-8-strong)"
  }.freeze

  LANE_COLUMNS = "grid grid-cols-[minmax(0,1fr)_7.5rem] gap-x-3 sm:grid-cols-[16rem_minmax(0,1fr)_8rem]"

  # The map for the perspective a page or a rating stream is showing.
  #
  # @param matrix_data [Hash] `Assessments::MatrixDataBuilder#build`
  # @param scoring [Hash] the perspective the hero renders
  # @param context [Symbol] :self, :manager or :alignment
  # @param whose [String, nil] the assessee's name; nil when the viewer is the assessee
  # @param content_only [Boolean] just what `CONTENT_ID` holds, for a stream
  # @return [Views::Assessments::CapabilityMapModal]
  def self.for(matrix_data:, scoring:, context:, whose: nil, content_only: false)
    code = matrix_data[:merged_levels].find { |l| l[:ordinal] == matrix_data[:person_level] }&.dig(:level_code)
    new(
      shape: Assessments::CapabilityShape.new(
        categories: matrix_data[:categories], scoring: scoring, merged_levels: matrix_data[:merged_levels],
        person_level: matrix_data[:person_level], context: context
      ),
      subject: "#{whose || 'You'} at #{code}", assessed_as: whose ? "assessed" : "you", content_only: content_only
    )
  end

  # @param shape [Assessments::CapabilityShape]
  # @param subject [String] who and where, "Alex at E3"
  # @param assessed_as [String] the assessed ring's label, "you" or "assessed"
  # @param content_only [Boolean] render just what `CONTENT_ID` holds
  def initialize(shape:, subject:, assessed_as: "you", content_only: false)
    @shape = shape
    @subject = subject
    @assessed_as = assessed_as
    @content_only = content_only
  end

  def view_template
    return content if @content_only

    render Components::Kit::Modal.new(
      id: ID, title: "Capability map", size: :"6xl", standalone: false,
      panel_data: { controller: "capability-map", capability_map_content_value: CONTENT_ID,
                    action: "mouseover->capability-map#light mouseout->capability-map#dim " \
                            "focusin->capability-map#light focusout->capability-map#dim" }
    ) do |modal|
      modal.body { div(id: CONTENT_ID) { content } }
    end
  end

  private

  def content
    p(class: "text-sm text-muted -mt-1 mb-4") do
      "#{@subject}. #{how_to_read} Open a capability from its spoke or its lane."
    end
    div(class: "grid gap-6 lg:grid-cols-[minmax(20rem,29rem)_minmax(0,1fr)] lg:items-start") do
      div(class: "mx-auto w-full max-w-sm lg:sticky lg:top-0 lg:max-w-none") do
        render Views::Assessments::CapabilityRadar.new(shape: @shape, size: :detailed, assessed_as: @assessed_as)
      end
      div { lanes }
    end
  end

  def how_to_read
    return "The radar's rim is #{@shape.codes.first} met." if @shape.codes.one?

    "At the radar's centre is #{@shape.codes.first} met, and each ring is the next level."
  end

  def lanes
    axis
    @shape.groups.each do |group|
      div(class: "#{LANE_COLUMNS} items-center px-2 pt-4 pb-1", data: { capability_lane_group: group.name.to_s }) do
        span(class: "sm:col-span-2") { render Components::Kit::Tag.new(group.name.to_s, category: group.hue) }
        span(class: "text-right text-sm font-bold tabular-nums #{tone_text(group.state)}", title: (state_label(group.state) if group.score)) do
          "#{percent(group.score)}%" if group.score
        end
      end
      group.points.each { |point| lane(point) }
    end
  end

  def axis
    div(class: "#{LANE_COLUMNS} px-2 text-[11px] text-muted", aria: { hidden: "true" }) do
      span(class: "hidden sm:block")
      div(class: "relative hidden h-4 sm:block") do
        @shape.codes.each_with_index do |code, i|
          span(class: [ "absolute -translate-x-1/2 tabular-nums", axis_tone(i) ], style: "left: #{left(i)}") { code }
        end
      end
      span(class: "col-start-2 text-right sm:col-start-3") { "Level reached" }
    end
  end

  def axis_tone(index)
    return "font-bold text-default" if index == @shape.assessed_index
    "font-bold text-score-ahead" if index == @shape.assessed_index + 1
  end

  def lane(point)
    a(href: "#cell-#{point.stable_id}-#{@shape.person_level}",
      class: "#{LANE_COLUMNS} items-center rounded-md px-2 py-1.5 text-sm text-default " \
             "hover:bg-overlay-hover data-[hot=true]:bg-overlay-hover " \
             "focus-visible:outline-2 focus-visible:outline-offset-[-2px] focus-visible:outline-focus",
      title: point.name,
      data: { capability_lane: point.number, capability_map_key: point.number,
              controller: "continue-assessing",
              action: "click->modal#close click->continue-assessing#focus",
              continue_assessing_capability_stable_id_value: point.stable_id,
              continue_assessing_level_ordinal_value: @shape.person_level }) do
      span(class: "flex min-w-0 items-center gap-2") do
        span(class: "grid size-5 shrink-0 place-items-center rounded-full text-[10px] font-bold #{Components::Kit::Tag::CATEGORIES.fetch(point.hue)}") do
          point.number.to_s
        end
        span(class: "flex min-w-0 flex-col items-start gap-0.5 sm:flex-row sm:items-center sm:gap-2") do
          span(class: "line-clamp-2") { point.name }
          render Components::Kit::Badge.new("! Blocked", tone: :warning, size: :sm) if point.blocked
        end
      end
      track(point)
      span(class: "text-right text-xs text-muted tabular-nums whitespace-nowrap") { point.label }
    end
  end

  def track(point)
    span(class: "relative hidden h-4 sm:block", aria: { hidden: "true" }) do
      span(class: "absolute inset-y-0 rounded-sm bg-overlay-muted",
           style: "left: #{left(@shape.assessed_index)}; width: #{width_of_next_band}")
      @shape.codes.each_index do |i|
        span(class: "absolute inset-y-0.5 w-px bg-(--gos-border-subtle)", style: "left: #{left(i)}")
      end
      span(class: "absolute inset-x-0 top-[7px] h-0.5 rounded-full bg-neutral-subtle")
      next unless point.reached

      span(class: "absolute left-0 top-[5px] h-1.5 rounded-full #{FILL.fetch(point.hue)}",
           style: "width: #{left(point.reached)}")
      span(class: "absolute top-0.5 -ml-1.5 size-3 rounded-full border-2 border-(--gos-surface-overlay) " \
                  "#{FILL.fetch(point.hue)}",
           style: "left: #{left(point.reached)}")
    end
  end

  def left(position) = "#{(@shape.fraction(position) * 100).round(2)}%"

  def width_of_next_band
    above = @shape.assessed_index + 1
    return "0%" if above >= @shape.codes.size

    "#{((@shape.fraction(above) - @shape.fraction(@shape.assessed_index)) * 100).round(2)}%"
  end
end
