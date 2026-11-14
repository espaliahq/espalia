# frozen_string_literal: true

# One path of a plan along the calendar ([#298](https://github.com/espaliahq/espalia/issues/298), mockup 04). It draws
# `team_planning_timeline` and decides none of its rules: blocks, lanes, moves
# and backfills arrive laid out.
#
# A wide screen shows the path as a grid, a column per step. A phone shows one
# step at a time, so each lane there says where its person came from and goes
# to, since the neighbouring steps are out of sight.
class Views::Plans::Timeline < Views::Base
  UNASSIGNED = "Unassigned"

  # The leaf a path from `from_id` reaches by taking the first "then" at each step.
  #
  # @param scenarios [Array<Hash>] from `team_planning_scenarios`
  # @param from_id [String]
  # @return [String]
  def self.first_leaf(scenarios, from_id)
    thens = scenarios.select { it[:relation] == "then" }.group_by { it[:parent_id] }
    id = from_id
    id = thens[id].first[:scenario_id] while thens[id]
    id
  end

  # @param timeline [Hash] from `team_planning_timeline`
  # @param scenarios [Array<Hash>] from `team_planning_scenarios`
  # @param step [Integer] the step a phone shows, from the left
  def initialize(timeline:, scenarios:, step: 0)
    @timeline = timeline
    @scenarios = scenarios.index_by { it[:scenario_id] }
    @all_scenarios = scenarios
    @step = step.clamp(0, columns.size - 1)
  end

  def view_template
    div(class: "space-y-4") do
      path_line
      if lanes_by_id.empty?
        p(class: "text-sm text-muted") { "No one is placed on this path yet." }
      else
        wide_grid
        phone_step
      end
    end
  end

  private

  def path_line
    p(class: "text-sm text-muted") do
      plain "Showing the path to "
      strong(class: "font-medium text-default") { step_name(columns.size - 1) }
      plain ". "
      plain(other_paths == 1 ? "One other path runs through this plan; " : "#{other_paths} other paths run through this plan; ") if other_paths.positive?
      plain "choose an alternative under a step to follow another." if other_paths.positive?
    end
    then_links(class: "text-sm") if @timeline[:next_ids].any?
  end

  def then_links(**attrs)
    p(**attrs) do
      span(class: "text-muted") { "Then: " }
      @timeline[:next_ids].each_with_index do |id, index|
        plain ", " if index.positive?
        path_link(id)
      end
    end
  end

  def alternatives(index)
    ids = columns[index][:alternative_ids]
    return if ids.empty?

    p(class: "mt-1 text-sm") do
      span(class: "text-muted") { "or instead " }
      ids.each_with_index do |id, i|
        plain ", " if i.positive?
        path_link(id)
      end
    end
  end

  def path_link(id)
    a(href: timeline_plan_path(@timeline[:plan_id], scenario: self.class.first_leaf(@all_scenarios, id)),
      class: "text-link hover:text-link-hover underline") { @scenarios.dig(id, :name) }
  end

  # -- Wide: a grid, a column per step -------------------------------------

  def wide_grid
    div(class: "hidden overflow-x-auto rounded-lg border border-default bg-default md:block") do
      div(class: "grid min-w-max text-sm", style: "grid-template-columns: minmax(6rem, 9rem) repeat(#{columns.size}, minmax(11rem, 1fr))",
          data: { timeline_grid: "" }) do
        @row = 1
        header_row
        @timeline[:blocks].each { wide_block(it) }
        wide_unassigned if unassigned_lanes.any?
      end
    end
  end

  def header_row
    div(class: "border-b border-default px-3 py-2 text-xs font-semibold uppercase text-muted", style: cell(1, 1)) { "Step" }
    columns.each_index do |index|
      div(class: "border-b border-l border-default px-3 py-2", style: cell(1, index + 2), data: { timeline_step: index }) do
        p(class: "font-semibold text-default") { step_name(index) }
        p(class: "text-muted") { period(index) }
        alternatives(index)
      end
    end
    @row += 1
  end

  def wide_block(block)
    block_heading(block_title(block), subtitle: continues_from(block))
    block[:lane_ids].each { |lane_id| wide_lane(lane_id) { |bar| in_block?(bar, block) } }
  end

  def wide_unassigned
    block_heading(UNASSIGNED, subtitle: nil)
    unassigned_lanes.each { |lane_id| wide_lane(lane_id) { |bar| bar[:unit_id].nil? } }
  end

  def block_heading(title, subtitle:)
    div(class: "bg-subtle px-3 py-1.5", style: "grid-row: #{@row}; grid-column: 1 / -1") do
      h3(class: "inline font-semibold text-default") { title }
      span(class: "ml-2 text-muted") { subtitle } if subtitle
    end
    @row += 1
  end

  def wide_lane(lane_id, &in_block)
    lane = lanes_by_id.fetch(lane_id)
    bars = lane[:bars].select(&in_block)
    return if bars.empty?

    div(class: "px-3 py-1.5 text-xs font-medium uppercase text-muted", style: cell(@row, 1)) { lane_label(bars.first) }
    bars.each do |bar|
      div(class: "px-1 py-1", style: "grid-row: #{@row}; grid-column: #{bar[:from] + 2} / #{bar[:to] + 3}") do
        bar_box(lane, bar) do
          span(class: "sr-only") { "#{span_of(bar)}: " }
          bar_text(lane, bar, starts: bar[:from], ends: bar[:to])
        end
      end
    end
    @row += 1
  end

  def cell(row, column) = "grid-row: #{row}; grid-column: #{column}"

  # -- Phone: one step at a time --------------------------------------------

  def phone_step
    div(class: "space-y-4 md:hidden", data: { timeline_phone: "" }) do
      step_picker
      div(class: "rounded-lg border border-default bg-default p-3") do
        h3(class: "font-semibold text-default") { step_name(@step) }
        p(class: "text-sm text-muted") { period(@step) }
        alternatives(@step)
      end
      @timeline[:blocks].each { phone_block(it) }
      phone_unassigned
    end
  end

  def step_picker
    nav(aria: { label: "Steps on this path" }) do
      p(class: "mb-2 text-sm text-muted") { "Step #{@step + 1} of #{columns.size}" }
      ol(class: "flex flex-wrap gap-2 text-sm") do
        columns.each_index do |index|
          current = index == @step
          li do
            a(href: timeline_plan_path(@timeline[:plan_id], scenario: @timeline[:scenario_id], step: index),
              aria: { current: ("step" if current) },
              class: "inline-flex min-h-11 items-center rounded-full border px-3 #{current ? 'border-brand bg-brand-subtle font-medium text-default' : 'border-default text-muted hover:text-default'}") do
              step_name(index)
            end
          end
        end
      end
    end
  end

  def phone_block(block)
    lane_ids = block[:lane_ids].select { |id| lanes_by_id.fetch(id)[:bars].any? { in_block?(it, block) && covers?(it) } }
    return if lane_ids.empty?

    phone_section(unit_name(@step, block[:units][@step]&.dig(:unit_id)) || block_title(block)) do
      lane_ids.each { |id| phone_lane(id) { |bar| in_block?(bar, block) && covers?(bar) } }
    end
  end

  def phone_unassigned
    lane_ids = unassigned_lanes.select { |id| lanes_by_id.fetch(id)[:bars].any? { it[:unit_id].nil? && covers?(it) } }
    return if lane_ids.empty?

    phone_section(UNASSIGNED) { lane_ids.each { |id| phone_lane(id) { |bar| bar[:unit_id].nil? && covers?(bar) } } }
  end

  def phone_section(title, &)
    section(class: "rounded-lg border border-default bg-default") do
      h3(class: "border-b border-default bg-subtle px-3 py-2 font-semibold text-default") { title }
      ul(class: "divide-y divide-subtle", &)
    end
  end

  def phone_lane(lane_id, &in_step)
    lane = lanes_by_id.fetch(lane_id)
    lane[:bars].select(&in_step).each do |bar|
      li(class: "px-3 py-2") do
        p(class: "text-xs font-medium uppercase text-muted") { lane_label(bar) }
        div(class: "mt-1") { bar_box(lane, bar) { bar_text(lane, bar, starts: @step, ends: @step) } }
      end
    end
  end

  def covers?(bar) = (bar[:from]..bar[:to]).cover?(@step)

  # -- A bar ------------------------------------------------------------------

  def bar_box(lane, bar, &)
    position = bar[:kind] == "position"
    div(class: "flex flex-wrap items-baseline gap-x-2 rounded border px-2 py-1 text-default " \
               "#{position ? 'border-dashed border-emphasized bg-default' : 'border-default bg-subtle'}",
        data: { timeline_lane: lane[:lane_id] }, &)
  end

  # What a bar says between columns `starts` and `ends`: where it came from if
  # it arrives at `starts`, where it goes if it leaves after `ends`.
  def bar_text(lane, bar, starts:, ends:)
    arrival = arrival(lane, bar) if bar[:from] == starts
    span(class: "font-medium") { arrival } if arrival
    span { subject(bar) }
    departure = departure(lane, bar, starts..ends)
    span(class: "text-muted") { departure } if departure
    onward = onward(lane, bar) if bar[:to] == ends
    span(class: "font-medium") { onward } if onward
  end

  def subject(bar)
    return person_subject(bar) if bar[:kind] == "person"

    position = @timeline[:positions].fetch(bar[:subject_id], {})
    what = [ position[:role_name], position[:level_name] ].compact.join(", ")
    if bar[:replaces_id]
      "Replaces #{name(bar[:replaces_id])}. Backfill#{", #{what}" if what.present?}"
    else
      "Open position#{", #{what}" if what.present?}"
    end
  end

  def person_subject(bar)
    share = bar[:allocation] && bar[:allocation].to_f < 1 ? "#{(bar[:allocation].to_f * 100).round}% " : ""
    "#{share}#{name(bar[:subject_id])}"
  end

  def arrival(lane, bar)
    return if bar[:from].zero?

    move = lane[:moves].find { it[:after] == bar[:from] - 1 && joined?(it, bar) }
    "from #{units_named(bar[:from] - 1, move[:left_unit_ids])}" if move
  end

  def onward(lane, bar)
    move = lane[:moves].find { it[:after] == bar[:to] && left?(it, bar) }
    "to #{units_named(bar[:to] + 1, move[:joined_unit_ids])}" if move
  end

  def departure(lane, bar, range)
    leaving = lane[:departures].find { it[:person_id] == bar[:subject_id] && range.cover?(it[:column]) }
    "leaves in #{step_name(leaving[:column])}" if leaving
  end

  def joined?(move, bar) = bar[:unit_id].nil? ? move[:joined_unit_ids].empty? : move[:joined_unit_ids].include?(bar[:unit_id])
  def left?(move, bar) = bar[:unit_id].nil? ? move[:left_unit_ids].empty? : move[:left_unit_ids].include?(bar[:unit_id])

  def units_named(column, unit_ids)
    return UNASSIGNED if unit_ids.empty?

    unit_ids.map { unit_name(column, it) || UNASSIGNED }.join(" and ")
  end

  def lane_label(bar)
    return bar[:role].to_s if bar[:kind] == "person"

    @timeline[:positions].dig(bar[:subject_id], :role_name).to_s
  end

  def span_of(bar) = bar[:from] == bar[:to] ? step_name(bar[:from]) : "#{step_name(bar[:from])} to #{step_name(bar[:to])}"

  # -- Lookups ----------------------------------------------------------------

  def columns = @timeline[:columns]

  def lanes_by_id = @lanes_by_id ||= @timeline[:lanes].index_by { it[:lane_id] }

  def unassigned_lanes = @timeline[:unassigned_lane_ids]

  def in_block?(bar, block) = bar[:unit_id] && block[:units][bar[:from]]&.dig(:unit_id) == bar[:unit_id]

  def unit_name(column, unit_id) = unit_names[[ column, unit_id ]]

  def unit_names
    @unit_names ||= @timeline[:blocks].each_with_object({}) do |block, names|
      block[:units].each_with_index { |unit, column| names[[ column, unit[:unit_id] ]] = unit[:name] if unit }
    end
  end

  def block_title(block) = block[:units].compact.map { it[:name] }.uniq.join(", then ")

  def continues_from(block)
    from = block[:continues_from_ids].filter_map { |id| @timeline[:blocks].find { it[:block_id] == id } }
    "carries on from #{from.map { block_title(it) }.join(' and ')}" if from.any?
  end

  def step_name(index)
    id = columns[index][:scenario_id]
    id == @timeline[:plan_id] ? "Today" : columns[index][:name]
  end

  def period(index)
    column = columns[index]
    return "As of #{date(column[:starts_on])}" unless column[:ends_on]

    "#{date(column[:starts_on])} to #{date(column[:ends_on])}"
  end

  def date(iso) = Date.iso8601(iso).strftime("%-d %b %Y")

  def name(person_id) = @timeline[:names].fetch(person_id, Person::FORMER_MEMBER)

  # Paths end at each scenario with nothing after it; this one ends at one of them.
  def other_paths
    @other_paths ||= @all_scenarios.count { |s| @all_scenarios.none? { it[:relation] == "then" && it[:parent_id] == s[:scenario_id] } } - 1
  end
end
