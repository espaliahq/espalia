# frozen_string_literal: true

# One scenario's organisation as a map (#227, mockup 01): a card per unit with
# its people by role and its open positions, then the people in no unit. It
# reads `team_planning_scenario_map`, so it shows any scenario as resolved.
#
# Other lanes add to it rather than reshape it. `unit_marks`, `person_marks`
# and `position_marks` each take a callable that returns components for a
# unit's heading, a person's row or an open position's row, and `summary`
# draws under the date line: capacity (#255), items needing attention (#257),
# a leaving mark and reporting lines (#256). An editor on a scenario other
# than Today can move people and positions ([#285](https://github.com/espaliahq/espalia/issues/285)): units take drops, and
# so do positions, for people. Each person row and each position is draggable,
# with a "Move…" button that opens {Views::Plans::MoveDialog} or
# {Views::Plans::MovePositionDialog}.
class Views::Plans::ScenarioMap < Views::Base
  NONE = ->(*) { [] }

  # @param position [Hash] a position from the map
  # @return [String] what the map calls it, such as "Backfill: Software Engineer"
  def self.position_label(position) = TeamPlanning::Baseline::Position.label(basis: position[:basis], role_name: position[:role_name])

  # @param positions [Array<Hash>] one unit's positions
  # @return [Hash{String => String}] each position's name, by position id, numbered as {TeamPlanning::Baseline::Position.names}
  def self.position_names(positions)
    TeamPlanning::Baseline::Position.names(positions.map { [ it[:position_id], position_label(it), it[:level_id] ] })
  end

  # @param map [Hash] from `team_planning_scenario_map`
  # @return [Hash{String => String}] every position's name, numbered within its unit
  def self.all_position_names(map) = map[:positions].group_by { it[:unit_id] }.values.map { position_names(it) }.reduce({}, :merge)

  # @param map [Hash] from `team_planning_scenario_map`
  # @param scenarios [Array<Hash>] from `team_planning_scenarios`, baseline first
  # @param unit_marks [#call] unit hash => components beside the unit's name
  # @param person_marks [#call] (person hash, place hash or nil) => components beside the person's name
  # @param position_marks [#call] position hash => components beside the position's label
  # @param summary [Phlex::SGML, nil] drawn under the date line, such as the capacity strip
  # @param can_edit [Boolean] whether the caller edits the plan: renaming the scenario shown, and moving people on it
  # @param can_upload_pay [Boolean] whether the caller may hold actual pay from a file, an editor with the see-pay right
  def initialize(map:, scenarios:, unit_marks: NONE, person_marks: NONE, position_marks: NONE, summary: nil, can_edit: false,
                 can_upload_pay: false)
    @can_edit = can_edit
    @can_upload_pay = can_upload_pay
    @map = map
    @moving = can_edit && !baseline?(map[:scenario_id])
    @scenarios = scenarios
    @unit_marks = unit_marks
    @person_marks = person_marks
    @position_marks = position_marks
    @summary = summary
  end

  def view_template
    div(class: "space-y-4") do
      scenario_picker
      p(class: "text-sm text-muted") { as_of_line }
      render @summary if @summary
      unresolved_notice if @map[:unresolved].any?
      div(class: "grid gap-4 md:grid-cols-2 2xl:grid-cols-3", data: ({ controller: "map-move" } if @moving)) do
        ordered_units.each { |unit, path| unit_card(unit, path) }
        unassigned_card if @moving || unassigned.any? || unplaced_positions.any?
      end
      empty_state if ordered_units.empty? && unassigned.empty? && unplaced_positions.empty?
      move_dialog if @moving
    end
  end

  private

  def scenario_picker
    div(class: "flex flex-wrap items-center gap-2") do
      scenario_pills
      scenario_select
      edit_button if @can_edit && !baseline?(@map[:scenario_id])
      upload_pay_link if @can_upload_pay
    end
  end

  def scenario_pills
    nav(aria: { label: "Scenario" }, class: "hidden sm:flex flex-wrap items-center gap-2 text-sm") do
      span(class: "text-muted") { "Showing" }
      @scenarios.each do |scenario|
        current = scenario[:scenario_id] == @map[:scenario_id]
        a(href: map_plan_path(@map[:plan_id], scenario: (scenario[:scenario_id] unless baseline?(scenario[:scenario_id]))),
          aria: { current: ("page" if current) },
          class: "rounded-full border px-3 py-1 #{current ? 'border-brand bg-brand-subtle font-medium text-default' : 'border-default text-muted hover:text-default'}") do
          scenario_label(scenario)
        end
      end
    end
  end

  # A phone has no room for a pill per scenario, so it picks from a list.
  def scenario_select
    form(action: map_plan_path(@map[:plan_id]), method: "get", class: "flex min-w-0 flex-1 items-center gap-2 text-sm sm:hidden",
         data: { controller: "auto-submit" }) do
      label(for: "map-scenario", class: "text-muted") { "Showing" }
      select(id: "map-scenario", name: "scenario", class: "min-w-0 flex-1 #{Components::Kit::Field::SELECT}",
             data: { action: "change->auto-submit#submit" }) do
        Views::Plans::ScenarioTable.tree(@scenarios).each do |scenario, depth|
          option(value: scenario[:scenario_id], selected: scenario[:scenario_id] == @map[:scenario_id]) do
            "#{'· ' * depth}#{scenario_label(scenario)}"
          end
        end
      end
      noscript { render Components::Kit::Button.new(variant: :outline, size: :sm, type: :submit) { "Show" } }
    end
  end

  def edit_button
    current = @scenarios.find { it[:scenario_id] == @map[:scenario_id] }
    return unless current

    render Components::Kit::Button.new(
      variant: :ghost, size: :sm,
      data: Views::Plans::ScenarioDialogs.edit_trigger(plan_scenario_path(@map[:plan_id], current[:scenario_id]), current)
    ) { "Edit…" }
    step = Views::Plans::ScenarioTable.dated_step(current, @scenarios)
    return unless step

    map_scenario = current[:scenario_id] unless current[:scenario_id] == step[:scenario_id]
    render Components::Kit::Button.new(variant: :ghost, size: :sm, compact: true,
                                       href: dates_plan_path(@map[:plan_id], scenario_id: step[:scenario_id], from: "map", map_scenario:)) { "Dates…" }
  end

  def upload_pay_link
    scenario = @map[:scenario_id] unless baseline?(@map[:scenario_id])
    render Components::Kit::Button.new(variant: :ghost, size: :sm, compact: true, href: pay_upload_plan_path(@map[:plan_id], scenario:)) { "Upload pay…" }
  end

  def scenario_label(scenario) = baseline?(scenario[:scenario_id]) ? "Today" : scenario[:name]

  # The baseline scenario has the plan's id.
  def baseline?(scenario_id) = scenario_id == @map[:plan_id]

  def as_of_line
    "The Org Graph on #{date(@map[:base_on])}, as known on #{date(@map[:known_on])}" \
      "#{', with this scenario\'s changes' unless baseline?(@map[:scenario_id])}. #{editing_hint}"
  end

  def editing_hint
    if @moving then "Drag a person or a position to another unit, or use Move…, to move it in this scenario. Drop a person on a position to place them in it."
    elsif @can_edit then "Read only. Pick or fork a scenario to move people."
    else "Read only."
    end
  end

  def move_dialog
    current = @scenarios.find { it[:scenario_id] == @map[:scenario_id] }
    scenario_name = current ? scenario_label(current) : "this scenario"
    render Views::Plans::MoveDialog.new(scenario_id: @map[:scenario_id], scenario_name:, units: ordered_units,
                                        positions: @map[:positions].group_by { it[:unit_id] })
    render Views::Plans::MovePositionDialog.new(scenario_id: @map[:scenario_id], scenario_name:, units: ordered_units)
  end

  # Where a unit card takes a dragged person.
  def drop_target(unit_id)
    return { map_unit: unit_id } unless @moving

    { map_unit: unit_id, action: "dragover->map-move#over dragleave->map-move#leave drop->map-move#drop" }
  end

  DROP_OVER = "data-[drop-over]:border-brand data-[drop-over]:bg-brand-subtle"

  def unresolved_notice
    render Components::Kit::Alert.new(tone: :warning, title: "Not on the map") do
      ul(class: "list-disc pl-5") do
        @map[:unresolved].each { |entry| li { "#{name(entry[:person_id])} #{entry[:why]}" } }
      end
    end
  end

  def unit_card(unit, path)
    people = members_of(unit[:id])
    section(aria: { labelledby: "map-unit-#{unit[:id]}" }, data: drop_target(unit[:id]),
            class: "rounded-lg border border-default bg-default #{DROP_OVER}") do
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
    section(aria: { labelledby: "map-unassigned" }, data: drop_target("unassigned"),
            class: "rounded-lg border border-dashed border-default bg-default #{DROP_OVER}") do
      header(class: "border-b border-subtle px-4 py-3") do
        h3(id: "map-unassigned", class: "text-base font-semibold text-default") { "Unassigned" }
        p(class: "mt-1 text-sm text-muted") { unassigned.any? || unplaced_positions.any? ? "#{unassigned_summary} in no unit" : "Drop someone here to take them out of a unit" }
      end
      if unassigned.any?
        ul(class: "px-2 py-2") do
          unassigned.sort_by { name(it[:id]) }.each { |person| person_row(person, nil) }
        end
      end
      unplaced_positions.each { position_row(it) }
    end
  end

  def unassigned_summary
    parts = []
    parts << count(unassigned.size, "person", "people") if unassigned.any?
    parts << count(unplaced_positions.size, "position", "positions") if unplaced_positions.any?
    parts.join(" and ")
  end

  def rows(people, positions)
    if people.empty? && positions.empty?
      p(class: "px-4 py-3 text-sm text-muted") { "Nobody yet." }
      return
    end

    div(class: "divide-y divide-subtle") do
      roles(people) if people.any?
      positions.each { position_row(it) }
    end
  end

  def roles(people)
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
    end
  end

  def person_row(person, place)
    li(data: person_data(person, place), draggable: ("true" if @moving),
       class: "flex flex-wrap items-center gap-x-2 gap-y-1 rounded px-2 py-1 text-sm#{' cursor-grab' if @moving}") do
      span(class: "w-10 shrink-0 tabular-nums text-muted") { allocation(place) } if place
      span(class: "min-w-0 font-medium text-default break-words") { name(person[:id]) }
      @person_marks.call(person, place).each { render it }
      span(class: "ml-auto flex items-center gap-2 text-muted") do
        span(class: "hidden sm:inline") { person[:title] } if person[:title].present?
        render Components::Kit::Badge.new(person[:level], size: :sm) if person[:level].present?
        move_button(person, place) if @moving
      end
    end
  end

  def person_data(person, place)
    return { map_person: person[:id] } unless @moving

    { map_person: person[:id], map_move_from: from(place), map_move_from_position: place&.dig(:position_id), map_drag: "person", action: "dragstart->map-move#start dragend->map-move#end" }
  end

  def move_button(person, place)
    render Components::Kit::Button.new(
      variant: :ghost, size: :sm, aria_label: "Move #{name(person[:id])}",
      data: Views::Plans::MoveDialog.trigger(url: plan_assignment_path(@map[:plan_id], person[:id]), name: name(person[:id]),
                                             from: from(place), place:, share: share(person, place))
    ) { "Move…" }
  end

  # What the place counts for: its allocation, or for a place the HRIS gave
  # none, the share MovePlace would write for it. Time spent outside a scoped
  # plan stands in as one place, so the share leaves it out.
  def share(person, place)
    index = place && person[:memberships].index { it.equal?(place) }
    return unless index

    places = person[:memberships].map { TeamPlanning::Baseline::Membership.new(**it) }
    away = person[:outside] && TeamPlanning::Baseline::Membership.new(unit_id: nil, allocation: person[:outside][:share], role: nil, position_id: nil)
    TeamPlanning::Baseline::Membership.shares(places + [ away ].compact)[index].second
  end

  def from(place) = place ? place[:unit_id] : Views::Plans::MoveDialog::UNASSIGNED

  def position_row(position)
    div(data: position_data(position), draggable: ("true" if movable?(position)), class: "px-4 py-2#{' cursor-grab' if movable?(position)}") do
      div(class: "flex flex-wrap items-center gap-x-2 gap-y-1 rounded border border-dashed border-default px-2 py-1 text-sm #{DROP_OVER}") do
        span(class: "font-medium text-default") { position_name(position) }
        open_fte_note(position[:open_fte])
        @position_marks.call(position).each { render it }
        render Components::Kit::Badge.new(position[:level_name], size: :sm) if position[:level_name]
        position.fetch(:occupants, []).sort_by { name(it[:person_id]) }.each do |occupant|
          span(data: { map_occupant: occupant[:person_id] }, class: "text-muted") { "#{name(occupant[:person_id])} · #{allocation(occupant)}" }
        end
        span(class: "ml-auto") { move_position_button(position) } if movable?(position)
      end
    end
  end

  # A position on the map moves; one whose unit a later scenario retired has
  # nowhere to move from, so it waits in Unassigned.
  def movable?(position) = @moving && units_by_id.key?(position[:unit_id])

  # A position takes dropped people, and drags to another unit itself.
  def position_data(position)
    return { map_position: position[:position_id] } unless movable?(position)

    { map_position: position[:position_id], map_move_from: position[:unit_id], map_drag: "position",
      action: "dragstart->map-move#start dragend->map-move#end dragover->map-move#over dragleave->map-move#leave drop->map-move#drop" }
  end

  def move_position_button(position)
    label = position_name(position)
    render Components::Kit::Button.new(
      variant: :ghost, size: :sm, aria_label: "Move #{label} in #{units_by_id[position[:unit_id]][:name]}",
      data: Views::Plans::MovePositionDialog.trigger(url: plan_position_path(@map[:plan_id], position[:position_id]), name: label,
                                                     from: position[:unit_id])
    ) { "Move…" }
  end

  def units_by_id = @units_by_id ||= @map[:units].index_by { it[:id] }

  def open_fte_note(open)
    if open.positive?
      span(class: "text-muted") { "#{fte(open)} FTE open" }
    elsif open.negative?
      span(class: "text-muted") { "#{fte(-open)} FTE over" }
    end
  end

  def empty_state
    render Components::Kit::EmptyState.new(title: "No units on this date", size: :panel)
  end

  def unit_summary(unit, people)
    parts = [ count(people.map { |person, _| person[:id] }.uniq.size, "person", "people") ]
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
  # Scenarios can set any unit's parent, so units caught in a loop come last
  # rather than not at all.
  def ordered_units
    @ordered_units ||= begin
      children = @map[:units].group_by { it[:parent_id] }
      ids = @map[:units].to_set { it[:id] }
      seen = Set.new
      walk = lambda do |unit, path|
        next [] unless seen.add?(unit[:id])

        [ [ unit, path ] ] + children.fetch(unit[:id], []).sort_by { it[:name] }.flat_map { walk.(it, path + [ unit[:name] ]) }
      end
      roots, rest = @map[:units].sort_by { it[:name] }.partition { !ids.include?(it[:parent_id]) }
      (roots + rest).flat_map { walk.(it, []) }
    end
  end

  # @return [Array<Array(Hash, Hash)>] each person in the unit with their place there
  def members_of(unit_id)
    @members ||= @map[:people].flat_map { |person| person[:memberships].map { [ person, it ] } }.group_by { |_, place| place[:unit_id] }
    @members.fetch(unit_id, [])
  end

  def positions_in(unit_id)
    @positions ||= @map[:positions].group_by { it[:unit_id] }
    @positions.fetch(unit_id, [])
  end

  def position_name(position)
    @position_names ||= @map[:positions].group_by { it[:unit_id] }.each_value.reduce({}) { |names, group| names.merge(self.class.position_names(group)) }
    @position_names.fetch(position[:position_id])
  end

  # Positions whose unit isn't on the map, such as one a later scenario retired.
  def unplaced_positions
    @unplaced_positions ||= begin
      ids = @map[:units].to_set { it[:id] }
      @map[:positions].reject { ids.include?(it[:unit_id]) }
    end
  end

  def unassigned
    @unassigned ||= begin
      ids = @map[:unassigned_ids].to_set
      @map[:people].select { ids.include?(it[:id]) }
    end
  end
end
