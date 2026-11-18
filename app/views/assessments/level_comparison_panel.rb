# frozen_string_literal: true

# The capability map's "Compared with your level" tab, drawn from
# `Operations::Assessments::LevelComparison`'s payload: the person's blades
# with a line across each at the group's middle score, level chips, and a
# lane per capability giving both scores in words.
class Views::Assessments::LevelComparisonPanel < Views::Base
  SWATCH = Views::Assessments::CapabilityMapModal::FILL
  # The lanes' track runs to two levels' worth, so met sits halfway.
  TRACK_TOP = 200.0
  PERSPECTIVES = { self: "self-ratings", manager: "manager ratings", alignment: "agreed ratings" }.freeze
  LANE_COLUMNS = "grid grid-cols-[minmax(0,1fr)_9rem] gap-x-3 sm:grid-cols-[13rem_minmax(0,1fr)_9rem]"

  # @param comparison [Hash] `Operations::Assessments::LevelComparison`'s payload, comparisons on
  # @param shape [Assessments::CapabilityShape, nil] the person's, read at the
  #   compared level, for the blades; nil when that level has no group scores
  # @param context [Symbol] the perspective the person's blades are read in
  # @param whose [String, nil] the assessee's name; nil when the viewer is the assessee
  def initialize(comparison:, shape:, context:, whose: nil)
    @comparison = comparison
    @shape = shape
    @context = context
    @whose = whose
    @capabilities = comparison[:capabilities].index_by { |c| c[:stable_id] }
    @categories = comparison[:categories].index_by { |c| c[:id] }
  end

  # @return [Integer] the level compared with, kept in the frame's reload source
  def level_ordinal = level[:ordinal]

  def view_template
    div(data: { level_comparison: code }) do
      if @comparison[:taken_on].nil?
        no_snapshot
      elsif level[:group_size].nil? || @shape.nil?
        too_few
      else
        compared
      end
    end
  end

  private

  def level = @comparison[:level]

  def code = level[:code]

  def plural = "#{code}s"

  def role_names = @comparison[:role][:name].pluralize

  def min = @comparison[:min_group_size]

  def no_snapshot
    render Components::Kit::EmptyState.new(title: "No group scores yet", size: :panel) do
      "The first snapshot of each level's middle scores is taken within the hour comparisons are turned on."
    end
  end

  def too_few
    render Components::Kit::EmptyState.new(title: "Not enough #{plural} to compare with", size: :panel) do
      suggestion = @comparison[:levels].find { |l| l[:ordinal] == @comparison[:suggested_ordinal] }
      "Fewer than #{min} #{role_names} at #{code} have a settled assessment, so a comparison could point at " \
        "one person.#{" Try #{suggestion[:code]}." if suggestion}"
    end
    div(class: "mt-4 flex justify-center") { level_chips }
  end

  def compared
    p(class: "text-sm text-muted -mt-1 mb-4") do
      plain "#{@whose ? "#{@whose}'s" : 'Your'} #{PERSPECTIVES.fetch(@context, 'ratings')}, scored at #{code}, " \
            "against the middle agreed score of the #{level[:group_size]} #{role_names} at #{code}, "
      strong(class: "text-default") { "as of #{Date.iso8601(@comparison[:taken_on]).strftime(LevelComparisonSnapshot::DATE_FORMAT)}" }
      plain ". The dashed circle is #{code} met; the line across each blade is the #{plural}."
    end
    div(class: "grid gap-6 lg:grid-cols-[minmax(18rem,26rem)_minmax(0,1fr)] lg:items-start") do
      div(class: "flex flex-col items-center gap-4 lg:sticky lg:top-0") do
        render Views::Assessments::ComparisonBlades.new(shape: @shape, medians: medians, label: picture_label)
        legend
        level_chips
      end
      div do
        lanes
        p(class: "mt-4 px-2 text-xs text-muted") do
          "Only middle scores show. Nobody in the comparison is named, and a level with fewer than #{min} people " \
            "has no comparison."
        end
      end
    end
  end

  # On the blades' scale, 1.0 the level met.
  def medians = @capabilities.transform_values { |c| c[:group_median] / 100.0 }

  def picture_label
    at_or_above = @capabilities.values.count { |c| c[:your_score] && c[:your_score] >= c[:group_median] }
    "#{at_or_above} of #{@shape.points.size} capabilities at or above the #{plural}' middle score"
  end

  def legend
    div(class: "flex flex-wrap justify-center gap-x-4 gap-y-1 text-xs text-muted", aria: { hidden: "true" }) do
      span(class: "flex items-center gap-1.5") do
        span(class: "inline-block h-1 w-3 rounded-full bg-(--gos-accent-strong)")
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
      @comparison[:levels].each do |l|
        detail = l[:available] ? "#{l[:group_size]} people" : "fewer than #{min}"
        render Components::Kit::Chip.new(
          "#{l[:code]}#{' (yours)' if l[:own]} · #{detail}",
          pressed: l[:ordinal] == level[:ordinal], disabled: !l[:available], size: :sm,
          data: { comparison_level: l[:code], action: "capability-map#show", capability_map_tab_param: "compare",
                  capability_map_compare_level_param: l[:ordinal], refresh_focus: "compare-#{l[:code]}" }
        )
      end
    end
  end

  def lanes
    @shape.groups.each do |group|
      category = @categories[group.category_id]
      div(class: "#{LANE_COLUMNS} items-center px-2 pt-4 pb-1") do
        span(class: "sm:col-span-2") { render Components::Kit::Tag.new(group.name.to_s, category: group.hue) }
        span(class: "text-right text-sm font-bold text-muted tabular-nums whitespace-nowrap") do
          both(category&.dig(:your_score), category&.dig(:group_median))
        end
      end
      group.points.each { |point| lane(point, @capabilities[point.stable_id]) }
    end
  end

  def lane(point, capability)
    div(class: "#{LANE_COLUMNS} items-center px-2 py-1.5 text-sm text-default", data: { comparison_lane: point.number }) do
      span(class: "line-clamp-2") { point.name }
      track(point.hue, capability)
      span(class: "text-right text-xs text-muted tabular-nums whitespace-nowrap", data: { comparison_scores: true }) do
        both(capability&.dig(:your_score), capability&.dig(:group_median))
      end
    end
  end

  def both(yours, theirs)
    plain "You "
    strong(class: "text-default") { yours ? "#{yours}%" : "not rated" }
    plain " · #{plural} #{theirs ? "#{theirs}%" : 'no score'}"
  end

  def track(hue, capability)
    span(class: "relative hidden h-4 sm:block", aria: { hidden: "true" }) do
      span(class: "absolute inset-x-0 top-[7px] h-0.5 rounded-full bg-neutral-subtle")
      span(class: "absolute inset-y-0 w-px border-l border-dashed border-(--gos-content-muted)", style: "left: 50%")
      next unless capability

      if capability[:your_score]
        span(class: "absolute left-0 top-[5px] h-1.5 rounded-full #{SWATCH.fetch(hue)}",
             style: "width: #{along(capability[:your_score])}")
      end
      span(class: "absolute top-0 h-4 w-1 -ml-0.5 rounded-full bg-(--gos-accent-strong) " \
                  "ring-2 ring-(--gos-surface-overlay)",
           style: "left: #{along(capability[:group_median])}")
    end
  end

  def along(percent) = "#{((percent / TRACK_TOP).clamp(0.0, 1.0) * 100).round(2)}%"
end
