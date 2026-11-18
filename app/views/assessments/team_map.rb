# frozen_string_literal: true

# The team capability map, drawn from `Operations::Assessments::TeamCapabilities`'s
# payload: the team's blades large, beside a lane per capability giving the
# team's score and how many are short. Its controls are links inside its own
# frame, so each choice reloads the map alone.
class Views::Assessments::TeamMap < Views::Base
  include Views::Assessments::Concerns::TeamControls

  register_element :turbo_frame

  ID = "team-map"
  RATINGS_SWITCH = { "manager" => "Manager", "self" => "Self", "aligned" => "Aligned" }.freeze
  # A lane's track runs to twice met, so met sits halfway.
  TRACK_TOP = 200.0
  LANE = "grid grid-cols-[minmax(0,1fr)_auto] items-center gap-x-3 sm:grid-cols-[13rem_minmax(0,1fr)_auto]"

  # @param team [Hash] `Operations::Assessments::TeamCapabilities`'s payload
  def initialize(team:)
    @team = team
  end

  def view_template
    turbo_frame(id: ID) do
      lead
      controls
      if @team[:role].nil? || @team[:scored].zero?
        render Components::Kit::EmptyState.new(title: "Nobody in view has a score yet", size: :panel)
      else
        map
      end
    end
  end

  private

  def team_path(**overrides) = team_map_assessments_path(team_choices.merge(overrides).compact)

  def capabilities = @team[:capabilities]

  def level_code = @team[:levels].find { |l| l[:ordinal] == @team[:level_ordinal] }&.dig(:code)

  def lead
    p(class: "text-sm text-muted -mt-1 mb-4") do
      plain "Your #{people_count}#{" at #{level_code}" if level_code}, #{RATINGS.fetch(@team[:ratings])}. "
      plain "Each blade is the team’s score against their own levels; the dashed circle is met."
    end
  end

  def controls
    div(class: "mb-6 flex flex-wrap items-center gap-3") do
      people_switch if @team[:indirect_reports]
      role_menu if roles?
      ratings_switch
    end
    level_chips if @team[:levels].any?
    compare_control unless comparison[:reason] == "off" || @team[:role].nil?
  end

  def comparison = @team[:comparison]

  def compared? = comparison[:shown]

  def group_name = @team.dig(:role, :name).to_s.pluralize

  # Compared with nothing reads `reason: "none"`; anything else is the line or why there is none.
  def compare_control
    div(class: "-mt-3 mb-6 flex flex-wrap items-center gap-3") do
      span(class: "text-sm text-muted", id: "team-compare-label") { "Compare with" }
      render Components::Kit::SegmentedControl.new(aria: { labelledby: "team-compare-label" }) do |control|
        control.segment("#{group_name} at the same levels", short: "Same levels", selected: comparison[:reason] != "none",
                                                                         href: team_path(team_compare: nil),
                                                                         data: { refresh_focus: "compare-level" })
        control.segment("Nothing", selected: comparison[:reason] == "none", href: team_path(team_compare: "none"),
                                   data: { refresh_focus: "compare-none" })
      end
      compare_note
    end
  end

  def compare_note
    note = case comparison[:reason]
    when nil then "#{comparison[:group_size]} #{group_name} at #{compared_codes.to_sentence}, as of " \
                  "#{Date.iso8601(comparison[:taken_on]).strftime(LevelComparisonSnapshot::DATE_FORMAT)}."
    when "no_snapshot" then "No group scores yet: the first snapshot is taken within the hour comparisons are turned on."
    when "too_few" then too_few_note
    end
    span(class: "text-xs text-muted", data: { team_compare_note: true }) { note } if note
  end

  # Nil at a level nobody in view is at, where there is nothing to compare.
  def too_few_note
    return if comparison[:short_levels].empty?

    "Fewer than #{comparison[:min_group_size]} #{group_name} at #{comparison[:short_levels].to_sentence} " \
      "have a settled assessment, so a line could point at one person."
  end

  def compared_codes
    @team[:levels].select { |l| l[:people].positive? && (@team[:level_ordinal].nil? || l[:ordinal] == @team[:level_ordinal]) }
      .map { |l| l[:code] }
  end

  def ratings_switch
    render Components::Kit::SegmentedControl.new(label: "Ratings shown") do |control|
      RATINGS_SWITCH.each do |key, label|
        control.segment(label, selected: @team[:ratings] == key, href: team_path(team_ratings: (key unless key == "manager")),
                               data: { refresh_focus: "ratings-#{key}" })
      end
    end
  end

  # Every level on the role's ladder, each with how many on the role are at it.
  def level_chips
    div(class: "-mt-3 mb-6 overflow-x-auto") do
      render Components::Kit::SegmentedControl.new(label: "Level shown") do |control|
        control.segment("All levels #{@team[:levels].sum { |l| l[:people] }}", selected: @team[:level_ordinal].nil?,
                                                                               href: team_path(team_level: nil), data: { team_level: "all", refresh_focus: "level-all" })
        @team[:levels].each do |level|
          control.segment("#{level[:code]} #{level[:people]}", selected: level[:ordinal] == @team[:level_ordinal],
                                                               href: team_path(team_level: level[:ordinal]),
                                                               data: { team_level: level[:code], refresh_focus: "level-#{level[:code]}" })
        end
      end
    end
  end

  def map
    div(class: "grid gap-6 lg:grid-cols-[minmax(18rem,26rem)_minmax(0,1fr)] lg:items-start") do
      div(class: "mx-auto w-full max-w-sm lg:sticky lg:top-0 lg:max-w-none") do
        render Views::Assessments::TeamBlades.new(
          capabilities:, size: "mx-auto w-full max-w-sm",
          label: "#{@team[:met]} of #{capabilities.size} capabilities met as a team", medians: compared?
        )
      end
      div { lanes }
    end
    p(class: "mt-6 text-xs text-muted") { "Names stay on the report cards; this map only combines them." }
  end

  def lanes
    capabilities.chunk_while { |a, b| a[:category_id] == b[:category_id] }.each do |group|
      div(class: "px-2 pt-4 pb-1") { render Components::Kit::Tag.new(group.first[:category_name].to_s, category: group.first[:hue]) }
      group.each { |capability| lane(capability) }
    end
  end

  def lane(capability)
    div(class: "#{LANE} rounded-md px-2 py-1.5 text-sm text-default", data: { team_lane: capability[:stable_id] }) do
      span(class: "line-clamp-2 min-w-0") { capability[:name] }
      track(capability)
      span(class: "text-right text-xs text-muted tabular-nums whitespace-nowrap max-sm:col-span-full max-sm:text-left") do
        median = group_median(capability)
        if capability[:score]
          plain "Team "
          strong(class: "text-default") { "#{capability[:score]}%" }
        else
          plain median ? "Team not rated" : "Not rated"
        end
        plain " · Group #{median}%" if median
        if capability[:score]
          plain " · "
          span(class: ("font-semibold text-warning" if capability[:short].positive?)) { "#{capability[:short]} short" }
        end
      end
    end
  end

  def track(capability)
    span(class: "relative hidden h-4 sm:block", aria: { hidden: "true" }) do
      span(class: "absolute inset-x-0 top-[5px] h-1.5 rounded-full bg-neutral-subtle")
      span(class: "absolute inset-y-0 left-1/2 border-l border-dashed border-(--gos-content-muted)")
      if capability[:score]
        span(class: "absolute left-0 top-[5px] h-1.5 rounded-full #{Views::Assessments::CapabilityMapModal::FILL.fetch(capability[:hue])}" \
                    "#{' opacity-60' if capability[:score] < 100}",
             style: "width: #{along(capability[:score])}")
      end
      median = group_median(capability)
      span(class: "absolute inset-y-0 -ml-px w-0.5 rounded-full bg-(--gos-accent-strong)", style: "left: #{along(median)}") if median
    end
  end

  def group_median(capability) = (capability[:group_median] if compared?)

  def along(percent) = "#{(percent.clamp(0, TRACK_TOP) / TRACK_TOP * 100).round(2)}%"
end
