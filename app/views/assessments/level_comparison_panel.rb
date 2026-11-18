# frozen_string_literal: true

# The capability map's "Compared with your level" tab: the person's blades
# with a line across each at the group's middle score, chips for their level
# and one either side, and a lane per capability giving both scores in
# words. A level whose group is under the tenant's minimum gets no numbers.
class Views::Assessments::LevelComparisonPanel < Views::Base
  include Views::Assessments::Concerns::ScoreScale

  DATE_FORMAT = "%-d %b %Y"
  SWATCH = Views::Assessments::CapabilityMapModal::FILL
  # The lanes' track runs to two levels' worth, so met sits halfway.
  TRACK_TOP = 2.0
  PERSPECTIVES = { self: "self-ratings", manager: "manager ratings", alignment: "agreed ratings" }.freeze

  # @param comparison [Assessments::LevelComparison]
  # @param selected [Integer] the ordinal compared with
  # @param shape [Assessments::CapabilityShape, nil] the person's, read at the
  #   selected level; nil when that level's group is under the minimum
  # @param role_name [String]
  # @param context [Symbol] the perspective the person's blades are read in
  # @param whose [String, nil] the assessee's name; nil when the viewer is the assessee
  def initialize(comparison:, selected:, shape:, role_name:, context:, whose: nil)
    @comparison = comparison
    @selected = comparison.levels.find { |level| level.ordinal == selected } || comparison.levels.find(&:own)
    @shape = shape
    @group = comparison.group_at(@selected.ordinal)
    @role_name = role_name
    @context = context
    @whose = whose
  end

  # @return [Integer] the level compared with, kept in the frame's reload source
  def level_ordinal = @selected.ordinal

  def view_template
    div(data: { level_comparison: @selected.code }) do
      if @comparison.taken_on.nil?
        no_snapshot
      elsif @group.nil? || @shape.nil?
        too_few
      else
        compared
      end
    end
  end

  private

  def code = @selected.code

  def plural = "#{code}s"

  def no_snapshot
    render Components::Kit::EmptyState.new(title: "No group scores yet", size: :panel) do
      "The first snapshot of each level's middle scores is taken within the hour comparisons are turned on."
    end
  end

  def too_few
    render Components::Kit::EmptyState.new(title: "Not enough #{plural} to compare with", size: :panel) do
      suggestion = @comparison.levels.find { |level| level.ordinal == @comparison.suggested_ordinal }
      "Fewer than #{@comparison.min_group_size} #{@role_name.pluralize} at #{code} have a settled assessment, " \
        "so a comparison could point at one person.#{" Try #{suggestion.code}." if suggestion}"
    end
    div(class: "mt-4 flex justify-center") { level_chips }
  end

  def compared
    p(class: "text-sm text-muted -mt-1 mb-4") do
      plain "#{@whose ? "#{@whose}'s" : 'Your'} #{PERSPECTIVES.fetch(@context, 'ratings')}, scored at #{code}, against the "
      plain "middle agreed score of the #{@group.group_size} #{@role_name.pluralize} at #{code}, "
      strong(class: "text-default") { "as of #{@comparison.taken_on.strftime(DATE_FORMAT)}" }
      plain ". The dashed circle is #{code} met; the line across each blade is the #{plural}."
    end
    div(class: "grid gap-6 lg:grid-cols-[minmax(18rem,26rem)_minmax(0,1fr)] lg:items-start") do
      div(class: "flex flex-col items-center gap-4 lg:sticky lg:top-0") do
        render Views::Assessments::ComparisonBlades.new(shape: @shape, medians: @group.capability_medians, label: picture_label)
        legend
        level_chips
      end
      div do
        lanes
        p(class: "mt-4 px-2 text-xs text-muted") do
          "Only middle scores show. Nobody in the comparison is named, and a level with fewer than " \
            "#{@comparison.min_group_size} people has no comparison."
        end
      end
    end
  end

  def picture_label
    near = @shape.points.count do |point|
      median = @group.capability_medians[point.stable_id]
      median && point.reached && score(point) >= median
    end
    "#{near} of #{@shape.points.size} capabilities at or above the #{plural}' middle score"
  end

  def legend
    div(class: "flex flex-wrap justify-center gap-x-4 gap-y-1 text-xs text-muted", aria: { hidden: "true" }) do
      span(class: "flex items-center gap-1.5") do
        span(class: "inline-block h-0.5 w-3 rounded-full bg-(--gos-content-default)")
        plain "#{plural} (middle score)"
      end
      span(class: "flex items-center gap-1.5") do
        span(class: "inline-block size-2.5 rounded-full border border-dashed border-(--gos-content-muted)")
        plain "#{code} met"
      end
    end
  end

  def level_chips
    div(class: "flex flex-wrap justify-center gap-2", role: "group", aria: { label: "Compare with a level" }) do
      @comparison.levels.each do |level|
        detail = level.available ? "#{level.group_size} people" : "fewer than #{@comparison.min_group_size}"
        render Components::Kit::Chip.new(
          "#{level.code}#{' (yours)' if level.own} · #{detail}", pressed: level.ordinal == @selected.ordinal,
                                                                  disabled: !level.available, size: :sm,
                                                                  data: { comparison_level: level.code, action: "capability-map#show",
                                                                          capability_map_tab_param: "compare",
                                                                          capability_map_compare_level_param: level.ordinal,
                                                                          refresh_focus: "compare-#{level.code}" }
        )
      end
    end
  end

  def lanes
    @shape.groups.each do |group|
      div(class: "#{LANE_COLUMNS} items-center px-2 pt-4 pb-1") do
        span(class: "sm:col-span-2") { render Components::Kit::Tag.new(group.name.to_s, category: group.hue) }
        span(class: "text-right text-sm font-bold text-muted tabular-nums whitespace-nowrap") do
          both(group.score, @group.category_medians[group.category_id])
        end
      end
      group.points.each { |point| lane(point) }
    end
  end

  def lane(point)
    median = @group.capability_medians[point.stable_id]
    div(class: "#{LANE_COLUMNS} items-center px-2 py-1.5 text-sm text-default", data: { comparison_lane: point.number }) do
      span(class: "line-clamp-2") { point.name }
      track(point, median)
      span(class: "text-right text-xs text-muted tabular-nums whitespace-nowrap", data: { comparison_scores: true }) do
        both(point.reached && score(point), median)
      end
    end
  end

  def both(yours, theirs)
    plain "You "
    strong(class: "text-default") { yours ? "#{percent(yours)}%" : "not rated" }
    plain " · #{plural} #{theirs ? "#{percent(theirs)}%" : '—'}"
  end

  def track(point, median)
    span(class: "relative hidden h-4 sm:block", aria: { hidden: "true" }) do
      span(class: "absolute inset-x-0 top-[7px] h-0.5 rounded-full bg-neutral-subtle")
      span(class: "absolute inset-y-0 w-px border-l border-dashed border-(--gos-content-muted)", style: "left: 50%")
      if point.reached
        span(class: "absolute left-0 top-[5px] h-1.5 rounded-full #{SWATCH.fetch(point.hue)}", style: "width: #{along(score(point))}")
      end
      span(class: "absolute top-0 h-4 w-0.5 -ml-px rounded-full bg-(--gos-content-default)", style: "left: #{along(median)}") if median
    end
  end

  LANE_COLUMNS = "grid grid-cols-[minmax(0,1fr)_9rem] gap-x-3 sm:grid-cols-[13rem_minmax(0,1fr)_9rem]"
  private_constant :LANE_COLUMNS

  # The score a point's blade stands for, 1.0 being the compared level met.
  def score(point) = point.reached - @shape.assessed_index + 1

  def along(value) = "#{((value / TRACK_TOP).clamp(0.0, 1.0) * 100).round(2)}%"
end
