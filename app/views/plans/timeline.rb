# frozen_string_literal: true

# One path of a plan along the calendar ([#298](https://github.com/espaliahq/espalia/issues/298), mockup 04). It draws
# `team_planning_timeline` and decides none of its rules: blocks, lanes, moves
# and backfills arrive laid out.
#
# A wide screen shows the path as a grid, a column per step. A phone shows one
# step at a time, so each lane there says where its person came from and goes
# to, since the neighbouring steps are out of sight.
#
# An editor moves people in a step ([#309](https://github.com/espaliahq/espalia/issues/309)): drag a person's bar onto
# another unit in a column the bar covers, or use its "Move…". Either opens
# that step's {Views::Plans::MoveDialog}, so it is the map's move, written in
# the column's scenario. A bar that starts with a change of place, a new
# position or a departure also has "When…", which moves that change a step
# earlier or later. Today, the first column, takes no moves. On a wide screen
# the bar's edge also drags that change one step either way
# ([#393](https://github.com/espaliahq/espalia/issues/393)): the drop clicks the
# matching "When…" item, and the menu stays the keyboard and phone path.
class Views::Plans::Timeline < Views::Base
  UNASSIGNED = "Unassigned"
  UNNAMED = "Unnamed step"
  UNASSIGNED_ID = Views::Plans::MoveDialog::UNASSIGNED

  # The leaf a path from `from_id` reaches by taking the first "then" at each
  # step, and passing up through the rest of a split step.
  #
  # @param scenarios [Array<Hash>] from `team_planning_scenarios`
  # @param from_id [String]
  # @return [String]
  def self.first_leaf(scenarios, from_id, thens: then_index(scenarios))
    id = from_id
    id = thens[id].first[:scenario_id] while thens[id]
    id
  end

  def self.then_index(scenarios) = scenarios.select { Views::Plans::ScenarioDialogs.onward?(it) }.group_by { it[:parent_id] }

  # @param timeline [Hash] from `team_planning_timeline`
  # @param scenarios [Array<Hash>] from `team_planning_scenarios`
  # @param step [Integer] the step a phone shows, from the left
  # @param can_edit [Boolean] whether the viewer edits the plan
  def initialize(timeline:, scenarios:, step: 0, can_edit: false)
    @timeline = timeline
    @moving = can_edit && timeline[:columns].size > 1
    @scenarios = scenarios.index_by { it[:scenario_id] }
    @all_scenarios = scenarios
    @thens = self.class.then_index(scenarios)
    @step = step.clamp(0, columns.size - 1)
  end

  def view_template
    div(class: "space-y-4") do
      path_line
      render Components::Kit::EmptyState.new(title: "No one is placed on this path yet.", size: :panel) if lanes_by_id.empty?
      wide_grid
      phone_step
      move_dialogs if @moving
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

  # An alternative stands in the same step, so a phone stays on it.
  def alternatives(index)
    ids = columns[index][:alternative_ids]
    return if ids.empty?

    p(class: "mt-1 text-sm") do
      span(class: "text-muted") { "or instead " }
      ids.each_with_index do |id, i|
        plain ", " if i.positive?
        path_link(id, step: index)
      end
    end
  end

  def path_link(id, step: nil)
    a(href: timeline_plan_path(@timeline[:plan_id], scenario: self.class.first_leaf(@all_scenarios, id, thens: @thens), step:),
      class: "text-link hover:text-link-hover underline") { scenario_name(id) }
  end

  # -- Wide: a grid, a column per step -------------------------------------

  def wide_grid
    div(class: "group/move hidden overflow-x-auto rounded-lg border border-default bg-default md:block",
        data: ({ controller: "map-move timeline-shift" } if @moving)) do
      div(class: "grid text-sm", style: "grid-template-columns: minmax(6rem, 9rem) repeat(#{columns.size}, minmax(11rem, 1fr)); " \
                                        "min-width: #{9 + (11 * columns.size)}rem",
          data: { timeline_grid: "" }) do
        @row = 1
        header_row
        @timeline[:blocks].each { wide_block(it) }
        wide_unassigned if @moving || unassigned_lanes.any?
        shift_targets if @moving
      end
    end
  end

  def header_row
    div(class: "border-b border-default px-3 py-2 text-xs font-semibold uppercase text-muted", style: "grid-row: 1 / 3; grid-column: 1") { "Step" }
    columns.each_index do |index|
      div(class: "border-l border-default px-3 pt-2 pb-1", style: cell(1, index + 2), data: { timeline_step: index }) do
        p(class: "font-semibold text-default") { step_name(index) }
        p(class: "text-muted") { period(index) }
        today_continues(index)
        alternatives(index)
        walk_line(@timeline[:walk][index], class: "mt-1")
        # Keeps its line while unseen, so the header row doesn't grow under the pointer mid-drag.
        p(class: "invisible font-medium text-brand", data: { timeline_shift_hint: index }) { "Move here" } if @moving
      end
    end
    @row += 1
    figures_row
  end

  # The figures arrive after the grid is drawn and usable, as a row of their
  # own, so a slow or failed load never holds up the path.
  def figures_row
    div(class: "grid border-b border-default", style: "grid-row: #{@row}; grid-column: 2 / -1; grid-template-columns: subgrid",
        data: { controller: "frame-error", frame_error_quiet_value: true }) do
      render Views::Plans::TimelineFigures.new(src: figures_path)
      render Components::Shared::FrameLoadError.new(id: "#{Views::Plans::TimelineFigures::WIDE_ID}-error", subject: "the figures",
                                                    inline: true, classes: "border-l border-default px-3 pb-2 [grid-column:1/-1]")
    end
    @row += 1
  end

  def figures_path(**) = timeline_figures_plan_path(@timeline[:plan_id], scenario: @timeline[:scenario_id], **)

  def wide_block(block)
    block_heading(block_title(block), subtitle: continues_from(block), walk: block[:walk], lives: ->(index) { block[:units][index] || changed?(block[:walk][index]) })
    drop_cells(->(index) { block[:units][index]&.dig(:unit_id) }) do
      block[:lane_ids].each { |lane_id| wide_lane(lane_id) { |bar| in_block?(bar, block) } }
    end
  end

  def wide_unassigned
    block_heading(UNASSIGNED, subtitle: nil, walk: @timeline[:unassigned_walk], lives: ->(index) { counted?(@timeline[:unassigned_walk][index]) })
    drop_cells(->(_) { UNASSIGNED_ID }) do
      unassigned_lanes.each { |lane_id| wide_lane(lane_id) { |bar| bar[:unit_id].nil? } }
    end
  end

  # Behind a block's lanes, a cell per step takes a dropped bar into that unit.
  def drop_cells(unit_in)
    first = @row
    yield
    return unless @moving

    empty_row if @row == first

    (1...columns.size).each do |index|
      unit_id = unit_in.(index)
      next unless unit_id

      div(class: "z-0 border-l border-subtle data-[drop-over]:bg-brand-subtle", style: "grid-row: #{first} / #{@row}; grid-column: #{index + 2}",
          data: { map_unit: unit_id, map_step: index, action: "dragover->map-move#over dragleave->map-move#leave drop->map-move#drop" })
    end
  end

  # A block with nobody in it still needs a row to drop on.
  def empty_row
    div(class: "min-h-10", style: cell(@row, 1))
    @row += 1
  end

  # The title takes the label column so each step's walk sits under its own
  # step, in the same row: a walk never widens a column or adds a row.
  def block_heading(title, subtitle:, walk:, lives:)
    div(class: "bg-subtle", style: "grid-row: #{@row}; grid-column: 1 / -1", data: { timeline_band: "" })
    div(class: "min-w-0 px-3 py-1.5 break-words", style: cell(@row, 1)) do
      h3(class: "font-semibold text-default") { title }
      p(class: "text-xs text-muted") { subtitle } if subtitle
    end
    walk.each_with_index do |counts, index|
      next unless lives.(index)

      div(class: "pointer-events-none min-w-0 px-3 py-1.5", style: cell(@row, index + 2), data: { timeline_walk: index }) do
        walk_line(counts, label: step_name(index))
      end
    end
    @row += 1
  end

  # A leaver and their backfill share the step the leaver goes in, so a bar
  # that overlaps one before it takes a row of its own. So does a new role,
  # since a row shows one.
  def wide_lane(lane_id, &in_block)
    lane = lanes_by_id.fetch(lane_id)
    rows = lane[:bars].select(&in_block).each_with_object([]) do |bar, packed|
      row = packed.find do |bars|
        lane_label(bars.first) == lane_label(bar) && bars.none? { it[:to] >= bar[:from] && bar[:to] >= it[:from] }
      end
      row ? row << bar : packed << [ bar ]
    end
    rows.each do |bars|
      div(class: "px-3 py-1.5 text-xs font-medium uppercase text-muted", style: cell(@row, 1)) { lane_label(bars.first) }
      bars.each { wide_bar(lane, it) }
      @row += 1
    end
  end

  def wide_bar(lane, bar)
    shifts = shifts(lane, bar, bar[:from]..bar[:to])
    div(class: "relative z-10 px-1 py-1 group-data-[dragging]/move:pointer-events-none has-[[aria-expanded=true]]:z-20 data-[shifting]:opacity-60",
        style: "grid-row: #{@row}; grid-column: #{bar[:from] + 2} / #{bar[:to] + 3}") do
      bar_box(lane, bar, steps: movable_steps(bar), shifts:) do
        span(class: "sr-only") { "#{span_of(bar)}: " }
        bar_text(lane, bar, starts: bar[:from], ends: bar[:to])
      end
      GRIP_SIDE.each_key { |edge| edge_grip(edge, shifts.filter_map { |column, facet, _, to| to if grip_edge(bar, column, facet) == edge }) }
    end
  end

  def cell(row, column) = "grid-row: #{row}; grid-column: #{column}"

  # -- Phone: one step at a time --------------------------------------------

  def phone_step
    div(class: "space-y-4 md:hidden", data: { timeline_phone: "" }) do
      step_picker
      render Components::Kit::Card.new(title: step_name(@step), density: :compact) do |card|
        card.body do
          p(class: "text-sm text-muted") { period(@step) }
          today_continues(@step)
          alternatives(@step)
          walk_line(@timeline[:walk][@step], class: "mt-1")
          div(data: { controller: "frame-error", frame_error_quiet_value: true }) do
            render Views::Plans::TimelineFigures.new(src: figures_path(layout: "phone", step: @step), phone: true, step: @step)
            render Components::Shared::FrameLoadError.new(id: "#{Views::Plans::TimelineFigures::PHONE_ID}-error", subject: "the figures",
                                                          inline: true, classes: "mt-1")
          end
        end
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
    walk = block[:walk][@step]
    return if lane_ids.empty? && !changed?(walk)

    phone_section(unit_name(@step, block[:units][@step]&.dig(:unit_id)) || block_title(block), walk: (walk if block[:units][@step] || changed?(walk)), lanes: lane_ids.any?) do
      lane_ids.each { |id| phone_lane(id) { |bar| in_block?(bar, block) && covers?(bar) } }
    end
  end

  def phone_unassigned
    lane_ids = unassigned_lanes.select { |id| lanes_by_id.fetch(id)[:bars].any? { it[:unit_id].nil? && covers?(it) } }
    return if lane_ids.empty? && !changed?(@timeline[:unassigned_walk][@step])

    phone_section(UNASSIGNED, walk: @timeline[:unassigned_walk][@step], lanes: lane_ids.any?) { lane_ids.each { |id| phone_lane(id) { |bar| bar[:unit_id].nil? && covers?(bar) } } }
  end

  def phone_section(title, walk:, lanes:, &block)
    render Components::Kit::Card.new(title:, variant: :flush, density: :compact) do |card|
      card.body do
        walk_line(walk, class: "px-3 pb-2")
        ul(class: "divide-y divide-subtle border-t border-default", &block) if lanes
      end
    end
  end

  def phone_lane(lane_id, &in_step)
    lane = lanes_by_id.fetch(lane_id)
    lane[:bars].select(&in_step).each do |bar|
      li(class: "px-3 py-2") do
        p(class: "text-xs font-medium uppercase text-muted") { lane_label(bar) }
        div(class: "mt-1") do
          bar_box(lane, bar, steps: movable_steps(bar) & [ @step ], shifts: shifts(lane, bar, @step..@step), drag: false) do
            bar_text(lane, bar, starts: @step, ends: @step)
          end
        end
      end
    end
  end

  def covers?(bar) = (bar[:from]..bar[:to]).cover?(@step)

  # -- A bar ------------------------------------------------------------------

  def bar_box(lane, bar, steps: [], shifts: [], drag: true, &content)
    position = bar[:kind] == "position"
    div(class: "flex flex-wrap items-center gap-x-2 rounded border px-2 py-1 text-default " \
               "#{position ? 'border-dashed border-emphasized bg-default' : 'border-default bg-subtle'}#{' cursor-grab' if drag && steps.any?}",
        draggable: ("true" if drag && steps.any?), data: { timeline_lane: lane[:lane_id], **(drag ? drag_data(bar, steps) : {}) }) do
      content.call
      span(class: "ml-auto flex items-center gap-1") do
        move_control(bar, steps) if steps.any?
        when_control(bar, shifts) if shifts.any?
      end
    end
  end

  # -- Moving a person in a step ----------------------------------------------

  def movable_steps(bar)
    return [] unless @moving && bar[:kind] == "person"

    ([ bar[:from], 1 ].max..bar[:to]).to_a
  end

  def drag_data(bar, steps)
    return {} if steps.empty?

    { map_person: bar[:subject_id], map_drag: "person", map_move_from: bar[:unit_id] || UNASSIGNED_ID,
      map_move_from_position: bar[:position_id], map_from_step: steps.first, map_to_step: steps.last,
      action: "dragstart->map-move#start dragend->map-move#end" }
  end

  # One step moves from a button; a bar across several asks which step.
  def move_control(bar, steps)
    label = "Move #{name(bar[:subject_id])}"
    span do
      if steps.one?
        render Components::Kit::Button.new(variant: :ghost, size: :sm, compact: true, aria_label: "#{label} in #{step_name(steps.first)}",
                                           data: move_trigger(bar, steps.first)) { "Move…" }
      else
        render Components::Kit::Dropdown.new(strategy: :fixed) do |menu|
          menu.trigger(label:, button: { variant: :ghost, size: :sm, compact: true }) { "Move…" }
          menu.menu(label:) do
            steps.each { |step| menu.item(data: move_trigger(bar, step)) { "In #{step_name(step)}" } }
          end
        end
      end
    end
  end

  def move_trigger(bar, step)
    Views::Plans::MoveDialog.trigger(
      url: plan_assignment_path(@timeline[:plan_id], bar[:subject_id]), name: name(bar[:subject_id]),
      from: bar[:unit_id] || UNASSIGNED_ID, place: { position_id: bar[:position_id], role: bar[:role] },
      share: share_in(bar, step), dialog: move_dialog_id(step)
    ).merge(move_at: bar[:unit_id] || UNASSIGNED_ID) # the dialog here lists units, not positions
  end

  def share_in(bar, step) = bar[:shares]&.dig(step - bar[:from])

  # -- Moving a change a step earlier or later --------------------------------

  SHIFT_WORDS = { "assignment" => "Change place in %s instead", "departure" => "Leave in %s instead",
                  "position" => "Open it in %s instead", "position_change" => "Move the %s change to %s" }.freeze

  # The changes a bar shows, in `range`, that a step makes itself: the place
  # it starts with, the departure it shows, or for a position each step that
  # opens or changes it (a new level keeps the bar going). Each moves to the
  # column before or after; never into Today.
  def shifts(lane, bar, range)
    return [] unless @moving

    changes = bar[:kind] == "person" ? person_changes(lane, bar, range) : position_changes(bar, range)
    changes.select { |column, facet| movable?(column, bar[:subject_id], facet) }.flat_map do |column, facet, words|
      [ ([ column, facet, "earlier", column - 1, words ] if column >= 2), ([ column, facet, "later", column + 1, words ] if column + 1 < columns.size) ].compact
    end
  end

  def person_changes(lane, bar, range)
    changes = []
    changes << [ bar[:from], "assignment", "assignment" ] if range.cover?(bar[:from]) && bar[:from].positive?
    leaving = lane[:departures].find { it[:person_id] == bar[:subject_id] && (bar[:from]..bar[:to]).cover?(it[:column]) && range.cover?(it[:column]) }
    changes << [ leaving[:column], "departure", "departure" ] if leaving
    changes
  end

  def position_changes(bar, range)
    (bar[:from]..bar[:to]).select { range.cover?(it) && it.positive? }
                          .map { [ it, "position", it == bar[:from] ? "position" : "position_change" ] }
  end

  def movable?(column, subject_id, facet) = columns[column].fetch(:movable, []).include?({ subject_id:, facet: })

  def when_control(bar, shifts)
    label = "Change when, for #{subject_name(bar)}"
    render Components::Kit::Dropdown.new(strategy: :fixed) do |menu|
      menu.trigger(label:, button: { variant: :ghost, size: :sm, compact: true }) { "When…" }
      menu.menu(label:, width: "w-64") do
        shifts.each do |column, facet, direction, to, words|
          edge = grip_edge(bar, column, facet)
          menu.item(href: shift_path(bar, column, facet, direction, to), data: { turbo_method: :post, timeline_shift: ("#{edge}:#{to}" if edge) }) do
            shift_words(words, column, to)
          end
        end
      end
    end
  end

  # A position can change in several steps along one bar, so its later
  # changes name the step each comes from.
  def shift_words(words, column, to)
    steps = words == "position_change" ? [ column, to ] : [ to ]
    sprintf(SHIFT_WORDS.fetch(words), *steps.map { step_name(it) })
  end

  def shift_path(bar, column, facet, direction, to)
    plan_change_moves_path(@timeline[:plan_id], return_to: timeline_plan_path(@timeline[:plan_id], scenario: @timeline[:scenario_id], step: @step),
                                                move: { scenario_id: columns[column][:scenario_id], subject_id: bar[:subject_id], facet:, direction:,
                                                        to_scenario_id: (columns[to][:scenario_id] if direction == "later") })
  end

  # -- Dragging a bar's edge --------------------------------------------------

  GRIP_SIDE = { "start" => "left-0", "end" => "right-0" }.freeze

  # Sits over the bar's padding and the box's outer edge, so it doesn't widen
  # the bar; a press there drags the edge, and anywhere else on the box still
  # starts the drag to another unit
  # ([#309](https://github.com/espaliahq/espalia/issues/309)). It is
  # pointer-only: the "When…" menu beside it is the same move for keyboards,
  # screen readers and phones, and the target that meets the 24px floor.
  def edge_grip(edge, steps)
    return if steps.empty?

    span(class: "absolute inset-y-1 #{GRIP_SIDE.fetch(edge)} w-2 cursor-col-resize touch-none rounded-sm hover:bg-brand-muted",
         aria: { hidden: "true" }, title: "Drag to move this a step earlier or later",
         data: { timeline_shift_edge: edge, timeline_shift_targets: steps.to_json, action: "pointerdown->timeline-shift#start" })
  end

  # The edge a bar's change sits on: a place or position at its start, a
  # departure at its end. A position's later changes sit on neither.
  def grip_edge(bar, column, facet)
    return "end" if facet == "departure" && column == bar[:to]

    "start" if facet != "departure" && column == bar[:from]
  end

  # A tint down each column, lit while an edge is dragged over a step it can move to.
  # Grid items paint in `order` before source order, so `order-first` lays it
  # under every heading and hint without moving it from its column.
  def shift_targets
    columns.each_index do |index|
      div(class: "pointer-events-none order-first hidden data-[lit]:block data-[lit]:bg-brand-subtle data-[over]:bg-brand-muted",
          style: "grid-row: 1 / #{@row}; grid-column: #{index + 2}", data: { timeline_shift_column: index })
    end
  end

  def subject_name(bar) = bar[:kind] == "person" ? name(bar[:subject_id]) : subject(bar)

  def move_dialog_id(step) = "#{Views::Plans::MoveDialog::ID}-#{step}"

  def move_dialogs
    back = timeline_plan_path(@timeline[:plan_id], scenario: @timeline[:scenario_id], step: @step)
    (1...columns.size).each do |index|
      render Views::Plans::MoveDialog.new(scenario_id: columns[index][:scenario_id], scenario_name: step_name(index),
                                          units: units_in(index), id: move_dialog_id(index), return_to: back)
    end
  end

  # The units of a step, in the order the blocks draw them, as the dialog lists them.
  def units_in(index)
    @timeline[:blocks].filter_map { it[:units][index] }.uniq { it[:unit_id] }.map { [ { id: it[:unit_id], name: it[:name] }, [] ] }
  end

  # What a bar says between columns `starts` and `ends`: where it came from if
  # it arrives at `starts`, where it goes if it leaves after `ends`.
  def bar_text(lane, bar, starts:, ends:)
    arrival = arrival(lane, bar) if bar[:from] == starts
    span(class: "font-medium") { arrival } if arrival
    span { subject(bar) }
    render Views::Plans::HiringNote.new(@timeline[:positions].dig(bar[:subject_id], :hiring, starts) || {}) if bar[:kind] == "position"
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

    move = lane[:moves].find { it[:person_id] == bar[:subject_id] && it[:after] == bar[:from] - 1 && joined?(it, bar) }
    return unless move

    move[:crossing] == "in" ? "joins this plan" : "from #{units_named(bar[:from] - 1, move[:left_unit_ids])}"
  end

  def onward(lane, bar)
    move = lane[:moves].find { it[:person_id] == bar[:subject_id] && it[:after] == bar[:to] && left?(it, bar) }
    return unless move

    move[:crossing] == "out" ? "moves out of this plan" : "to #{units_named(bar[:to] + 1, move[:joined_unit_ids])}"
  end

  def departure(lane, bar, range)
    leaving = lane[:departures].find { it[:person_id] == bar[:subject_id] && range.cover?(it[:column]) }
    "leaves in #{step_name(leaving[:column])}" if leaving
  end

  # A move names Unassigned as nil, as a bar does.
  def joined?(move, bar) = move[:joined_unit_ids].include?(bar[:unit_id])
  def left?(move, bar) = move[:left_unit_ids].include?(bar[:unit_id])

  def units_named(column, unit_ids)
    return UNASSIGNED if unit_ids.empty?

    unit_ids.map { unit_name(column, it) || UNASSIGNED }.join(" and ")
  end

  def lane_label(bar)
    return bar[:role].to_s if bar[:kind] == "person"

    @timeline[:positions].dig(bar[:subject_id], :role_name).to_s
  end

  def span_of(bar) = bar[:from] == bar[:to] ? step_name(bar[:from]) : "#{step_name(bar[:from])} to #{step_name(bar[:to])}"

  # -- The walk ---------------------------------------------------------------

  WALK_WORDS = { hires: "hired", departures: "left", transfers_in: "moved in", transfers_out: "moved out" }.freeze

  # One quiet line: "3 → 4 heads · 1 hired, 1 moved out", or "3 heads" for
  # today or a step that changes no one.
  # A heading row's cells name their step for a screen reader, as a bar does.
  def walk_line(walk, label: nil, **attrs)
    return unless walk

    p(class: "text-xs text-muted #{attrs.delete(:class)}", data: { walk: "" }, **attrs) do
      span(class: "sr-only") { "#{label}: " } if label
      changes = changes(walk)
      if changes.empty?
        plain heads(walk[:closing])
      else
        plain walk[:opening].to_s
        span(aria: { hidden: "true" }) { " → " }
        span(class: "sr-only") { " to " }
        plain "#{heads(walk[:closing])} · #{changes.join(', ')}"
      end
    end
  end

  def heads(count) = "#{count} #{'head'.pluralize(count)}"

  def changes(walk) = WALK_WORDS.filter_map { |key, word| "#{walk[key]} #{word}" if walk[key].to_i.positive? }

  def changed?(walk) = walk.present? && changes(walk).any?

  def counted?(walk) = walk.present? && (walk[:closing].positive? || changed?(walk))

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
    id == @timeline[:plan_id] ? "Today" : scenario_name(id)
  end

  def scenario_name(id) = @scenarios.dig(id, :name).presence || UNNAMED

  def period(index) = Views::Plans::ScenarioTable.period(@scenarios.fetch(columns[index][:scenario_id]))

  def today_continues(index)
    continues = Views::Plans::ScenarioTable.today_continues_to(@all_scenarios) if index.zero?
    p(class: "text-sm text-muted", data: { today_continues: continues.iso8601 }) { "Today continues to #{continues.strftime('%-d %b %Y')}" } if continues
  end

  def name(person_id) = @timeline[:names].fetch(person_id, Person::FORMER_MEMBER)

  # Paths end at each scenario with nothing after it. The one shown counts
  # among them only when it ends at one.
  def other_paths
    @other_paths ||= @all_scenarios.count { !@thens.key?(it[:scenario_id]) } - (@timeline[:next_ids].empty? ? 1 : 0)
  end
end
