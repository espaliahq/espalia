# frozen_string_literal: true

# One scenario's organisation as a map (#227, mockup 01): a card per unit with
# its people by role and its open positions, then the people in no unit. It
# reads `team_planning_scenario_map`, so it shows any scenario as resolved.
#
# Other lanes add to it rather than reshape it. `unit_marks` and
# `person_marks` each take a callable that returns components for a unit's
# heading or a person's row: capacity (#255), items needing attention (#257),
# a leaving mark and reporting lines (#256). Editing (3.12) hangs drop targets
# and drag handles on the `data-map-unit` and `data-map-person` hooks.
class Views::Plans::ScenarioMap < Views::Base
  NONE = ->(_) { [] }

  # @param map [Hash] from `team_planning_scenario_map`
  # @param scenarios [Array<Hash>] from `team_planning_scenarios`, baseline first
  # @param unit_marks [#call] unit hash => components beside the unit's name
  # @param person_marks [#call] person hash => components beside the person's name
  def initialize(map:, scenarios:, unit_marks: NONE, person_marks: NONE)
    @map = map
    @scenarios = scenarios
    @unit_marks = unit_marks
    @person_marks = person_marks
  end

  def view_template
    div(class: "space-y-4") do
      scenario_picker
      p(class: "text-sm text-muted") { as_of_line }
      unresolved_notice if @map[:unresolved].any?
      div(class: "grid gap-4 md:grid-cols-2 2xl:grid-cols-3") do
        ordered_units.each { |unit, path| unit_card(unit, path) }
        unassigned_card if unassigned.any?
      end
      empty_state if ordered_units.empty? && unassigned.empty?
    end
  end

  private

  def scenario_picker
    nav(aria: { label: "Scenario" }, class: "flex flex-wrap items-center gap-2 text-sm") do
      span(class: "text-muted") { "Showing" }
      @scenarios.each do |scenario|
        current = scenario[:scenario_id] == @map[:scenario_id]
        a(href: map_plan_path(@map[:plan_id], scenario: (scenario[:scenario_id] unless baseline?(scenario))),
          aria: { current: ("page" if current) },
          class: "rounded-full border px-3 py-1 #{current ? 'border-brand bg-brand-subtle font-medium text-default' : 'border-default text-muted hover:text-default'}") do
          scenario_label(scenario)
        end
      end
    end
  end

  def scenario_label(scenario) = baseline?(scenario) ? "Today" : scenario[:name]

  def baseline?(scenario) = scenario[:parent_id].nil?

  def as_of_line
    "The Org Graph on #{date(@map[:base_on])}, as known on #{date(@map[:known_on])}" \
      "#{', with this scenario\'s changes' unless @map[:scenario_id] == @map[:plan_id]}. Read only."
  end

  def unresolved_notice
    render Components::Kit::Alert.new(tone: :warning, title: "Not on the map") do
      ul(class: "list-disc pl-5") do
        @map[:unresolved].each { |entry| li { "#{name(entry[:person_id])} #{entry[:why]}" } }
      end
    end
  end

  def unit_card(unit, path)
    people = members_of(unit[:id])
    section(aria: { labelledby: "map-unit-#{unit[:id]}" }, data: { map_unit: unit[:id] },
            class: "rounded-lg border border-default bg-default") do
      header(class: "border-b border-subtle px-4 py-3") do
        p(class: "text-xs text-muted break-words") { path.join(" › ") } if path.any?
        div(class: "flex flex-wrap items-center gap-2") do
          h3(id: "map-unit-#{unit[:id]}", class: "text-base font-semibold text-default break-words") { unit[:name] }
          @unit_marks.call(unit).each { render it }
        end
        p(class: "mt-1 text-sm text-muted") { unit_summary(unit, people) }
      end
      rows(people, positions_in(unit[:id]))
    end
  end

  def unassigned_card
    section(aria: { labelledby: "map-unassigned" }, data: { map_unit: "unassigned" },
            class: "rounded-lg border border-dashed border-default bg-default") do
      header(class: "border-b border-subtle px-4 py-3") do
        h3(id: "map-unassigned", class: "text-base font-semibold text-default") { "Unassigned" }
        p(class: "mt-1 text-sm text-muted") { "#{count(unassigned.size, 'person', 'people')} in no unit" }
      end
      ul(class: "px-2 py-2") do
        unassigned.sort_by { name(it[:id]) }.each { |person| person_row(person, nil) }
      end
    end
  end

  def rows(people, positions)
    if people.empty? && positions.empty?
      p(class: "px-4 py-3 text-sm text-muted") { "Nobody yet." }
      return
    end

    groups = people.group_by { |_, place| place[:role].presence }
    dl(class: "divide-y divide-subtle") do
      groups.keys.sort_by { [ it.nil? ? 1 : 0, it.to_s ] }.each do |role|
        div(class: "flex gap-3 px-4 py-2") do
          dt(class: "w-12 shrink-0 pt-1 text-xs font-semibold uppercase text-muted break-words") { role || "No role" }
          dd(class: "min-w-0 flex-1") do
            ul(class: "space-y-1") { groups[role].sort_by { |person, _| name(person[:id]) }.each { |person, place| person_row(person, place) } }
          end
        end
      end
      positions.each { position_row(it) }
    end
  end

  def person_row(person, place)
    li(data: { map_person: person[:id] }, class: "flex flex-wrap items-center gap-x-2 gap-y-1 rounded px-2 py-1 text-sm") do
      span(class: "w-10 shrink-0 tabular-nums text-muted") { allocation(place) } if place
      span(class: "min-w-0 font-medium text-default break-words") { name(person[:id]) }
      @person_marks.call(person).each { render it }
      span(class: "ml-auto flex items-center gap-2 text-muted") do
        span(class: "hidden sm:inline") { person[:title] } if person[:title].present?
        render Components::Kit::Badge.new(person[:level], size: :sm) if person[:level].present?
      end
    end
  end

  def position_row(position)
    div(data: { map_position: position[:position_id] }, class: "px-4 py-2") do
      div(class: "flex flex-wrap items-center gap-x-2 gap-y-1 rounded border border-dashed border-default px-2 py-1 text-sm") do
        span(class: "font-medium text-default") { position_label(position) }
        span(class: "text-muted") { "#{fte(position[:open_fte])} FTE open" } if position[:open_fte].positive?
        render Components::Kit::Badge.new(position[:level_name], size: :sm) if position[:level_name]
      end
    end
  end

  def position_label(position)
    kind = position[:basis] == "backfill" ? "Backfill" : "New position"
    position[:role_name] ? "#{kind}: #{position[:role_name]}" : kind
  end

  def empty_state
    render Components::Kit::EmptyState.new(title: "No units on this date", size: :panel)
  end

  def unit_summary(unit, people)
    parts = [ count(people.size, "person", "people") ]
    parts << "#{fte(fte_of(people))} FTE" unless people.any? { |_, place| place[:allocation].nil? }
    owners = unit[:owner_ids].map { name(it) }
    parts << "owned by #{owners.to_sentence}" if owners.any?
    parts.join(" · ")
  end

  def fte_of(people) = people.sum { |person, place| place[:allocation].to_f * (person[:fte] || 1).to_f }

  def allocation(place) = place[:allocation].nil? ? "?" : "#{(place[:allocation].to_f * 100).round}%"

  def fte(value) = sprintf("%.1f", value)

  def count(n, one, many) = "#{n} #{n == 1 ? one : many}"

  def date(iso) = Date.iso8601(iso).strftime("%-d %b %Y")

  def name(person_id) = @map[:names].fetch(person_id, Person::FORMER_MEMBER)

  # Each unit with the names of the units above it, parents before children.
  def ordered_units
    @ordered_units ||= begin
      children = @map[:units].group_by { it[:parent_id] }
      ids = @map[:units].to_set { it[:id] }
      roots = @map[:units].reject { ids.include?(it[:parent_id]) }
      walk = lambda do |unit, path|
        [ [ unit, path ] ] + children.fetch(unit[:id], []).sort_by { it[:name] }.flat_map { walk.(it, path + [ unit[:name] ]) }
      end
      roots.sort_by { it[:name] }.flat_map { walk.(it, []) }
    end
  end

  # @return [Array<Array(Hash, Hash)>] each person in the unit with their place there
  def members_of(unit_id)
    @members ||= @map[:people].flat_map { |person| person[:memberships].map { [ person, it ] } }.group_by { |_, place| place[:unit_id] }
    @members.fetch(unit_id, [])
  end

  def positions_in(unit_id) = @map[:positions].select { it[:unit_id] == unit_id }

  def unassigned
    @unassigned ||= begin
      ids = @map[:unassigned_ids].to_set
      @map[:people].select { ids.include?(it[:id]) }
    end
  end
end
