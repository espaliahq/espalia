# frozen_string_literal: true

# The organisation a plan stands on: its root scenario, which changes
# nothing yet, resolved over {OrgGraph::AsOf} on the plan's base date as
# known at the end of the day before (decision 3). Later Org Graph edits,
# including any made on the base date itself, are drift, never part of it.
#
# {#structure} is ids only, so scenario resolution (story 3.2) can apply a
# plan's changes over it before anything is named. {#call} joins the names
# last, and a forgotten person reads as {Person::FORMER_MEMBER}.
#
# @example
#   map = TeamPlanning::Baseline.new(context:, plan:).call
#   map.unassigned_ids.map { map.name_of(it) }
class TeamPlanning::Baseline
  # The organisation as a plan sees it.
  #
  # @!attribute base_on [Date] the day it shows
  # @!attribute known_on [Date] read as known at the end of this day
  # @!attribute units [Array<Unit>] the live units, by name
  # @!attribute retired_units [Array<Unit>] units a scenario retired; the baseline has none, and a
  #   map read with `history: true` has those the Org Graph retired by its day
  # @!attribute successions [Array<Succession>] links a scenario made; the baseline has none, and a
  #   map read with `history: true` has those the Org Graph recorded by its day
  # @!attribute people [Array<Member>] the people employed that day, by id
  # @!attribute left_ids [Array<String>] people who had left; the baseline has none, and a map read
  #   with `history: true` has those the Org Graph had leave by its day
  # @!attribute unassigned_ids [Array<String>] the people in no live unit
  # @!attribute positions [Array<Position>] the open positions; the Org Graph has none, so only a plan adds them
  # @!attribute names [Hash{String => String}] person id => name, empty until joined
  # @!attribute rules [Rules] the rules the organisation follows
  # @!attribute unresolved [Array<Unresolved>] the people a plan places who aren't on the map
  # @!attribute step_ids [Array<String>] the scenarios of the step on screen: it and those it is an
  #   alternative of. A departure set in one of them marks the person leaving; one set earlier takes them off
  # @!attribute departed [Array<Departed>] the people a departure in an earlier step took off the map
  # @!attribute budget_lines [Array<BudgetLine>] the tenant's approved lines, read live, with the plan's changes on top
  # @!attribute orphaned_lines [Hash{String => String}] each tenant line the tenant has since removed, by id, to "set" or "cut", whichever change came last
  # @!attribute scope_ids [Array<String>, nil] the units the plan covers, each with everything under it; nil for the whole organisation
  # @!attribute outside [Array<Member>] the people outside the plan's scope, kept so a change can bring one in. Never shown
  # @!attribute cut_positions [Array<Position>] the positions in units outside the plan's scope. Never shown
  # @!attribute cut_unit_ids [Set<String>] the units, live or retired, outside the plan's scope. Never shown
  # @!attribute fundings [Hash{String => Array<Hash>}] position id => the draws a {TeamPlanning::Events::PositionFundingSet} sets
  # @!attribute held_cost_centres [Set<String>, nil] the cost centres a scoped plan's lines may name, fixed by its baseline; nil holds every line
  # @!attribute outside_lines [Array<BudgetLine>] the lines naming a cost centre the plan doesn't hold. Never shown, named or counted
  # @!attribute step [Range<Date>, nil] the days the scenario's figures run over, which resolution fills in; nil starts every seat
  Map = Data.define(:base_on, :known_on, :units, :retired_units, :successions, :people, :unassigned_ids, :positions, :names,
                    :rules, :unresolved, :step_ids, :departed, :left_ids, :budget_lines, :orphaned_lines, :fundings, :scope_ids, :outside,
                    :cut_positions, :cut_unit_ids, :held_cost_centres, :outside_lines, :step) do
    def initialize(retired_units: [], successions: [], unresolved: [], step_ids: [], departed: [], left_ids: [], budget_lines: [],
                   orphaned_lines: {}, fundings: {}, scope_ids: nil, outside: [], cut_positions: [], cut_unit_ids: Set.new,
                   held_cost_centres: nil, outside_lines: [], step: nil, **) = super

    # Takes off the map anyone a departure in an earlier step took, puts
    # each position's people in its unit, and anyone left in no live unit in
    # Unassigned. A placement in a closed position keeps its position but
    # has no unit.
    #
    # A plan with a scope keeps only the units it covers. A person with a
    # place in one is on the map; anyone else is outside. Someone on the map
    # whose places a change took out of every covered unit moves outside,
    # but one it left with no place stays, in Unassigned.
    #
    # @return [Map]
    def settled
      unit_of = position_units
      placed = ->(person) { person.with(memberships: person.memberships.map { it.position_id ? it.with(unit_id: unit_of[it.position_id]) : it }) }
      map = with(people: people.map(&placed), outside: outside.map(&placed))
      map = map.cut if scope_ids
      gone, staying = map.people.partition { it.departure && step_ids.exclude?(it.departure[:leaves_in_id]) }
      map = map.with(people: staying, departed: departed + gone.map { Departed.new(person_id: it.id, country: it.country, **it.departure) })
      live = map.units.to_set(&:id)
      map.with(unassigned_ids: map.people.reject { |person| person.memberships.any? { live.include?(it.unit_id) } }.map(&:id))
    end

    # @return [Map] only the covered units, and the people placed in them
    def cut
      covered = covered_ids
      map = with(units: units.select { covered.include?(it.id) }, retired_units: retired_units.select { covered.include?(it.id) },
                 cut_unit_ids: (cut_unit_ids | (units + retired_units).map(&:id)) - covered)
      known = map.known_unit_ids
      inside = ->(person, was_on) { person.memberships.any? { known.include?(it.unit_id) } || (was_on && person.memberships.none?(&:unit_id)) }
      people, leaving = map.people.partition { inside.(it, true) }
      joining, outside = map.outside.partition { inside.(it, false) }
      kept, gone = map.positions.partition { it.unit_id.nil? || known.include?(it.unit_id) }
      map.with(people: people + joining, outside: leaving + outside, positions: kept, cut_positions: (gone + cut_positions).uniq(&:id)).lines_cut
    end

    # @param cost_centres [Enumerable<String>] what the plan's baseline seats can draw on
    # @return [Map] holding only the lines {#holds_cost_centre?} keeps
    def holding_lines(cost_centres) = with(held_cost_centres: cost_centres.to_set { it.squish }).lines_cut

    # @param cost_centre [String, nil]
    # @return [Boolean] whether a line naming it is the plan's: one naming none is any seat's
    def holds_cost_centre?(cost_centre) = held_cost_centres.nil? || cost_centre.blank? || held_cost_centres.include?(cost_centre.squish)

    # Moves each line the plan doesn't hold to {#outside_lines}, and drops a
    # funding that draws on one, so the seat reads as the plan's own lines fund it.
    #
    # @return [Map]
    def lines_cut
      return self unless held_cost_centres

      held, away = (budget_lines + outside_lines).partition { holds_cost_centre?(it.cost_centre) }
      gone = away.to_set(&:id)
      with(budget_lines: held, outside_lines: away, fundings: fundings.reject { |_, draws| draws.any? { gone.include?(it[:budget_line_id]) } })
    end

    # @param line_id [String]
    # @return [Boolean] whether the map has the line, held or outside the plan's cost centres
    def line?(line_id) = (budget_lines + outside_lines).any? { it.id == line_id }

    # @param line_id [String]
    # @return [Boolean] whether the line is one the plan's cost centres leave out
    def outside_line?(line_id) = outside_lines.any? { it.id == line_id }

    # A position the cut took off the map still places its people outside,
    # so a later settle doesn't read them as placed in no unit.
    #
    # @return [Hash{String => String, nil}] each position's unit, by position id
    def position_units = (cut_positions + positions).to_h { [ it.id, it.unit_id ] }

    # @return [Set<String>] the units on the map, live or retired
    def known_unit_ids = (units + retired_units).to_set(&:id)

    # @param person_id [String]
    # @return [Boolean] whether the map holds them, on it or outside the plan's scope
    def holds?(person_id) = people.any? { it.id == person_id } || outside.any? { it.id == person_id }

    # @param person_id [String] someone the map {#holds?}
    # @yieldparam person [Member]
    # @yieldreturn [Member]
    # @return [Map] the person changed wherever the map holds them; the next settle decides which side they are on
    def updating(person_id)
      return with(people: people.map { it.id == person_id ? yield(it) : it }) if people.any? { it.id == person_id }

      with(outside: outside.map { it.id == person_id ? yield(it) : it })
    end

    # @return [Set<String>] the people outside the plan's scope, for a check run once per person
    def outside_ids = outside.to_set(&:id)

    # @return [Set<String>] the units and positions outside the plan's scope
    def cut_ids = cut_unit_ids | cut_positions.to_set(&:id)

    # @param member [Member]
    # @return [Array<Membership>] the places in units outside the plan's scope
    def outside_places(member)
      return [] unless scope_ids

      known = known_unit_ids
      member.memberships.select { it.unit_id && !known.include?(it.unit_id) }
    end

    # The shares a plan counts: those of places on the map, so a person half
    # inside the plan's scope counts as half.
    #
    # @param member [Member]
    # @return [Array<(Membership, Rational, Boolean)>] as {Membership.shares}
    def counted_shares(member)
      away = outside_places(member)
      Membership.shares(member.memberships).reject { |place, _, _| away.include?(place) }
    end

    # A leaver never fills the position that backfills them.
    #
    # @return [Hash{String => Position}] by id
    def positions_by_id = positions.index_by(&:id)

    # @return [Hash{String => Array<Array(Member, Membership)>}] position id => each person placed there, with the placement
    def occupants
      people.flat_map { |person| person.memberships.select { it.position_id && it.position_id != person.backfill_id }.map { [ person, it ] } }
        .group_by { it.last.position_id }
    end

    # @return [Hash{String => Array<String>}] position id => the people whose departure it backfills,
    #   leaving in this step or gone before it
    def backfills
      (people.filter_map { [ it.backfill_id, it.id ] if it.backfill_id } + departed.filter_map { [ it.position_id, it.person_id ] if it.position_id })
        .group_by(&:first).transform_values { it.map(&:last) }
    end

    # A placeholder hire fills the first position it is placed in, so it
    # starts when that seat does; one in no position starts with the step.
    #
    # @param member [Member]
    # @return [Boolean] whether the person is in post by the step's last day
    def started?(member)
      return true unless step && member.placeholder?

      position = member.memberships.lazy.filter_map { positions_by_id[it.position_id] if it.position_id }.first
      position.nil? || TeamPlanning::SeatStart.new(position).started_in?(step)
    end

    # @param position [Position]
    # @return [Boolean] whether the position's open seat has started by the step's last day
    def seat_started?(position) = step.nil? || TeamPlanning::SeatStart.new(position).started_in?(step)

    # The people whose line points at a person or a position. For a vacant
    # manager position, this is the span the open seat carries.
    #
    # @param id [String] a person id or a position id
    # @return [Array<String>] person ids, direct reports only
    def reports_of(id) = people.select { it.manager_id == id || it.manager_position_id == id }.map(&:id)

    # The lines above a person, nearest first. It stops at a person with no
    # manager, at a position (a seat has no line of its own; read its people
    # with {#occupants}), at someone off the map, or at a repeat, so a loop an
    # ancestor's edit made never spins.
    #
    # @param person_id [String]
    # @return [Array<Line>]
    def managers_above(person_id)
      by_id = people.index_by(&:id)
      lines = []
      seen = Set[person_id]
      while (line = by_id[person_id]&.line)
        lines << line
        break unless (person_id = line.person_id) && seen.add?(person_id)
      end
      lines
    end

    # The position's FTE less what its people fill: each one's allocation
    # times their FTE, an unknown FTE counting as full time. Below 0 when
    # the position is overfilled.
    #
    # @param position [Position]
    # @param occupants [Array<Array(Member, Membership)>] from {#occupants}
    # @return [Float]
    def open_fte(position, occupants)
      filled = occupants.sum { |person, placement| placement.allocation.to_f * person.fte_or_one.to_f }
      (position.fte.to_f - filled).round(4)
    end

    # Each person's allocations in live units, summed. A total over 1 is
    # never refused, so checks read it. nil means unknown: the HRIS gave a
    # place no allocation, and a check must not read unknown as
    # under-allocated. A place in a closed position or a gone unit counts
    # for nothing.
    #
    # @return [Hash{String => Float, nil}] person id => total
    def allocation_totals
      live = units.to_set(&:id)
      people.to_h do |person|
        away = outside_places(person)
        allocations = person.memberships.select { live.include?(it.unit_id) || away.include?(it) }.map(&:allocation)
        [ person.id, allocations.any?(&:nil?) ? nil : allocations.sum(&:to_f).round(4) ]
      end
    end

    # @return [Array<String>] every person id the map uses: its people, their
    #   managers, the units' owners and the people it can't place
    def person_ids
      ids = (people.flat_map { [ it.id, it.manager_id ] } + units.flat_map(&:owner_ids) + unresolved.map(&:person_id) +
        departed.map(&:person_id)).compact.uniq
      outside.empty? ? ids : ids - outside.map(&:id)
    end

    # @param person_id [String]
    # @return [String]
    def name_of(person_id) = names.fetch(person_id, Person::FORMER_MEMBER)

    # A unit follows the nearest unit at or above it that sets the rule, then
    # the plan-wide value. A unit gone from the map takes its rules with it.
    #
    # @param rule [String] a {TeamPlanning::RuleKind.rule_name}
    # @param unit_id [String, nil] nil for the whole plan
    # @return [Hash]
    # @raise [TeamPlanning::Error] for an unknown rule, or a unit not on the map
    def rule(rule, unit_id: nil) = rules.value_of(rule.to_s, along: unit_id ? units_up_from(unit_id) : [])

    # @param unit_id [String]
    # @return [Array<String>] the unit and each unit above it on the map, nearest first
    # @raise [TeamPlanning::Error] for a unit not on the map
    def units_up_from(unit_id)
      by_id = units.index_by(&:id)
      raise TeamPlanning::Error, "No such unit" unless by_id.key?(unit_id)

      chain = [ unit_id ]
      while (parent_id = by_id[chain.last].parent_id) && by_id.key?(parent_id) && chain.exclude?(parent_id)
        chain << parent_id
      end
      chain
    end

    private

    def covered_ids
      every = units + retired_units
      children = every.group_by(&:parent_id)
      covered = scope_ids.to_set & every.to_set(&:id)
      queue = covered.to_a
      while (id = queue.shift)
        children.fetch(id, []).each { queue << it.id if covered.add?(it.id) }
      end
      covered
    end
  end

  # The rules a map follows: each rule's value before the plan sets it, then
  # what the plan's scenarios set, by subject (the plan's id or a unit's).
  #
  # @!attribute plan_id [String] the subject that sets a rule plan-wide
  # @!attribute defaults [Hash{String => Hash}] by rule
  # @!attribute by_subject [Hash{String => Hash{String => Hash}}] subject id => rule => value
  Rules = Data.define(:plan_id, :defaults, :by_subject) do
    # @return [Rules] with the value in place
    def with_rule(subject_id, rule, value) = with(by_subject: by_subject.merge(subject_id => by_subject.fetch(subject_id, {}).merge(rule => value)))

    # @param rule [String]
    # @param along [Array<String>] unit ids, nearest first
    # @return [Hash]
    # @raise [TeamPlanning::Error] for a rule no kind names
    def value_of(rule, along:)
      raise TeamPlanning::Error, "No such rule" unless defaults.key?(rule)

      setter = (along + [ plan_id ]).find { by_subject.fetch(it, {}).key?(rule) }
      setter ? by_subject[setter][rule] : defaults[rule]
    end
  end

  # A live unit. `parent_id` is nil at the root.
  Unit = Data.define(:id, :name, :parent_id, :level_id, :owner_ids)

  # Units that carry on from others: a split, a merge or a replacement.
  Succession = Data.define(:id, :predecessor_ids, :successor_ids)

  # What {Member#planned_or_own} gives for a value the plan held and has
  # since lost to a destroyed key.
  UNKNOWN = :unknown

  # A person and their facts that day, with each place they hold. Their
  # line points at `manager_id` (the Org Graph's manager fact, or a plan's
  # change) or at `manager_position_id`, a vacant manager seat, or at
  # neither. `departure` is set while they are leaving: `leaves_in_id`, the
  # scenario whose step they leave in, and `position_id`, their backfill.
  #
  # What the plan holds about them stays sealed: `planned_level`, a promotion;
  # `plan_data`, the plan's corrections by field; `capacity_overrides`, a
  # planner's capacity figure by position or unit id; and for a hire the plan
  # added, `placeholder`, its label. Read a value through {#planned_or_own}.
  Member = Data.define(:id, :title, :level, :manager_id, :cost_centre, :site, :country, :fte, :employment_type,
                       :memberships, :manager_position_id, :departure, :planned_level, :plan_data, :placeholder,
                       :capacity_overrides) do
    def initialize(manager_position_id: nil, departure: nil, planned_level: nil, plan_data: {}, placeholder: nil,
                   capacity_overrides: {}, **) = super

    # A hire the plan added, which no Org Graph id names.
    #
    # @param id [String] minted by the plan
    # @param label [Shreddable::Value]
    # @return [Member]
    def self.placeholder(id, label)
      new(id:, title: nil, level: nil, manager_id: nil, cost_centre: nil, site: nil, country: nil, fte: nil,
          employment_type: nil, memberships: [], placeholder: label)
    end

    # The plan's value for a field where it holds one, else the Org Graph's.
    # A planned promotion wins over a corrected level. A value whose key is
    # gone reads as {UNKNOWN}, never as the Org Graph's: the plan said
    # something here, and nobody can now say what. A level the plan cleared
    # reads as none.
    #
    # @param field [Symbol] :level or :fte
    # @return [Object, Symbol] the value, nil when nobody holds one, or {UNKNOWN}
    def planned_or_own(field)
      return nil if field == :level && TeamPlanning::Events::LevelSet.cleared?(planned_level)

      value = (planned_level if field == :level) || plan_data[field]
      return public_send(field) unless value

      value.removed? ? UNKNOWN : value.reveal
    end

    # @return [Boolean] whether the plan holds a level for them, or holds that they have none
    def planned_level? = !(planned_level || plan_data[:level]).nil?

    # Their role and level through the tenant's title mapping. A level the
    # plan holds wins over a mapping's fixed level, so one it can't resolve,
    # removed or not a level ordinal, leaves the level unresolved. Capacity
    # and cost both read it, so they price a person at one level.
    #
    # @param titles [Integrations::HrisTitleResolution]
    # @return [Integrations::HrisTitleResolution::Target]
    def own_target(titles)
      ordinal = Integer(planned_or_own(:level), exception: false)
      return titles.target(title, ordinal) unless planned_level?

      own = titles.target(title, ordinal, planned_ordinal: ordinal)
      ordinal ? own : own.with(level: nil, ordinal: nil)
    end

    # @return [Boolean]
    def placeholder? = !placeholder.nil?

    # @return [Numeric] the FTE the plan counts, 1 when nobody knows it
    def fte_or_one
      fte = planned_or_own(:fte)
      fte.nil? || fte == UNKNOWN ? 1 : fte
    end

    # @return [Line, nil] nil when they report to nobody
    def line = manager_id || manager_position_id ? Line.new(person_id: manager_id, position_id: manager_position_id) : nil

    # @return [Boolean]
    def leaving? = !departure.nil?

    # @return [String, nil] the position backfilling them
    def backfill_id = departure&.dig(:position_id)
  end

  # Where a reporting line points: a person or a position, never both.
  Line = Data.define(:person_id, :position_id)

  # Someone a departure in an earlier step took off the map, the step they
  # left in, the position backfilling them, if any, and the date within the
  # step, if the plan gave one.
  Departed = Data.define(:person_id, :leaves_in_id, :position_id, :leaves_on, :country) do
    def initialize(leaves_on: nil, country: nil, **) = super

    # @return [Hash] as {TeamPlanning::Events::DepartureSet} set it, `leaves_on` only when given
    def departure = { leaves_in_id:, position_id: }.merge(leaves_on ? { leaves_on: } : {})
  end

  # A person's place in a unit, or in a position. A position's place takes
  # the position's unit when the map settles, and none once it closes.
  # `allocation` is nil when the HRIS gave none.
  Membership = Data.define(:unit_id, :allocation, :role, :position_id) do
    # An allocation the HRIS didn't give shares what the person's other
    # memberships leave.
    #
    # @param memberships [Array<Membership>]
    # @return [Array<(Membership, Rational, Boolean)>] each membership, its share, and whether it was recorded
    def self.shares(memberships)
      known = memberships.reject { it.allocation.nil? }.sum(0r) { Rational(it.allocation.to_s) }
      unknown = memberships.count { it.allocation.nil? }
      rest = unknown.zero? ? 0r : [ 1r - known, 0r ].max / unknown
      memberships.map { [ it, it.allocation.nil? ? rest : Rational(it.allocation.to_s), !it.allocation.nil? ] }
    end

    def initialize(position_id: nil, **) = super
  end

  # Someone a plan places who isn't on the map, so the placement waits:
  # `why` is "joined after the base date" (updating the plan's base date
  # brings them in) or "has left".
  Unresolved = Data.define(:person_id, :why)
  Unresolved::JOINED_LATER = "joined after the base date"
  Unresolved::LEFT = "has left"

  # An open position. Its role and level names are nil until joined, and stay
  # nil for a role or level the framework no longer has. Its cost centre is
  # its own label, nil when it has none. `opened_on` is the first day of the
  # earliest step in the chain that sets it, which resolution fills in.
  Position = Data.define(:id, :role_id, :level_id, :unit_id, :fte, :basis, :cost_centre, :role_name, :level_name,
                         :hiring_status, :target_start, :opened_on) do
    def initialize(cost_centre: nil, hiring_status: "not_started", target_start: nil, opened_on: nil, **) = super

    # @param basis [String]
    # @return [String] "committed" for a backfill, "planned" for a new position
    def self.budget_of(basis) = basis == "backfill" ? "committed" : "planned"

    # @return [String] see {.budget_of}
    def budget = self.class.budget_of(basis)

    # @param basis [String]
    # @param role_name [String, nil]
    # @return [String] what the map calls it, such as "Backfill: Software Engineer"
    def self.label(basis:, role_name:)
      kind = basis == "backfill" ? "Backfill" : "New position"
      role_name ? "#{kind}: #{role_name}" : kind
    end

    # @return [String] see {.label}
    def label = self.class.label(basis:, role_name:)

    # Positions in a unit that share a label and level are numbered oldest
    # first, so the map, the move dialog and the checks name each one alike.
    #
    # @param positions [Array<Array(String, String, String)>] one unit's positions, as [id, label, level id]
    # @return [Hash{String => String}] each position's name, by id
    def self.names(positions)
      alike = positions.group_by { |_, label, level_id| [ label, level_id ] }.transform_values { |group| group.map(&:first).sort }
      positions.to_h do |id, label, level_id|
        group = alike[[ label, level_id ]]
        [ id, group.size > 1 ? "#{label} (#{group.index(id) + 1})" : label ]
      end
    end
  end

  BUDGET_FIGURES = %i[starts_on ends_on origin approved_on amount currency period head_count role_id level_id role_name level_name
                      location cost_centre].freeze

  # A budget line as a scenario holds it. A plan's own amount stays sealed
  # until {#revealed}.
  #
  # @!attribute source [String] "tenant" as approved, "changed" by the plan, or "plan" for one the plan added
  BudgetLine = Data.define(:id, :starts_on, :ends_on, :origin, :approved_on, :amount, :currency, :period, :head_count,
                           :role_id, :level_id, :role_name, :level_name, :location, :cost_centre, :source) do
    # @param line [::BudgetLine]
    # @return [BudgetLine]
    def self.approved(line)
      new(id: line.id, **BUDGET_FIGURES.to_h { [ it, line.public_send(it) ] }, source: "tenant")
    end

    # @param id [String]
    # @param figures [Hash] a {TeamPlanning::Events::BudgetLineSet} end state
    # @param source [String]
    # @return [BudgetLine]
    def self.planned(id, figures, source:)
      dates = %i[starts_on ends_on approved_on].to_h { [ it, figures[it] && Date.iso8601(figures[it].to_s) ] }
      new(id:, **BUDGET_FIGURES.to_h { [ it, figures[it] ] }.merge(dates), source:)
    end

    # @return [BigDecimal, nil] the amount, nil when the line has none or the plan's key is gone
    def revealed_amount
      value = amount.is_a?(Shreddable::Value) ? (amount.removed? ? nil : amount.reveal) : amount
      value.nil? ? nil : BigDecimal(value.to_s)
    end
  end

  PLACEHOLDER_NAME = "Placeholder hire"

  # @param context [AuthorizationContext]
  # @param plan [TeamPlanningPlan]
  def initialize(context:, plan:)
    @context = context
    @plan = plan
  end

  # @return [Map] with names joined
  # @raise [Pundit::NotAuthorizedError] when the caller can't open the plan or see the Org Graph
  def call = named(structure)

  # @return [Map] by id, with no names
  # @raise [Pundit::NotAuthorizedError] when the caller can't open the plan or see the Org Graph
  def structure = CurrentPlanReads.fetch([ :baseline, *CurrentPlanReads.viewer(@context), @plan.id, @plan.base_on, known_on ]) { map_on(@plan.base_on, known_on:) }

  # The Org Graph as known the day before the base, or on the archive day if
  # that came first, so a fact recorded after archiving moves no figure.
  #
  # @return [Date]
  def known_on = [ @plan.base_on - 1, @plan.archived_on ].compact.min

  # The organisation on another day, in the shape {#structure} gives, so a
  # reader can hold the plan up against it.
  #
  # A plan's own map holds only the units, successions and leavers a scenario
  # made, so the Org Graph's are left out unless a reader asks for them.
  #
  # @param date [Date]
  # @param known_on [Date, nil] nil for what the Org Graph knows now
  # @param history [Boolean] whether to carry the units the Org Graph retired, the
  #   successions it recorded and the people it had leave, by that day
  # @param scoped [Boolean] false for the whole organisation, so a reader can
  #   find someone the plan moved out of its scope
  # @return [Map] by id, with no names
  # @raise [Pundit::NotAuthorizedError] when the caller can't open the plan or see the Org Graph
  def map_on(date, known_on: nil, history: false, scoped: true)
    Pundit.authorize(@context, @plan, :show?, policy_class: PlanPolicy)
    snapshot = OrgGraph::AsOf.new(context: @context, date:, known_on:).call

    places = snapshot.memberships.group_by(&:person_id)
    people = snapshot.people.map { |person| person_from(person, places.fetch(person.id, [])) }
    units = snapshot.units.map { Unit.new(**it.to_h.slice(*Unit.members)) }
    scope_ids = (@plan.scope_unit_ids.presence if scoped)
    map = Map.new(base_on: snapshot.date, known_on: snapshot.known_on, units:, people: scope_ids ? [] : people, outside: scope_ids ? people : [],
                  scope_ids:, unassigned_ids: [], positions: [], names: {}, step_ids: [ @plan.id ], budget_lines: approved_budget,
                  rules: Rules.new(plan_id: @plan.id, defaults: inputs.rule_defaults, by_subject: {})).settled
    map = map.holding_lines(held_on(date, known_on, map, units)) if scope_ids
    return map unless history

    map.with(retired_units: snapshot.retired_units.map { Unit.new(**it.to_h.slice(*Unit.members)) },
             successions: snapshot.successions.map { Succession.new(**it.to_h) }, left_ids: snapshot.left_ids)
  end

  # Joins the names of everyone the map names ({Map#person_ids}) and of each
  # position's role and level. A placeholder hire is named by its label, or
  # {PLACEHOLDER_NAME} once the plan's key is gone.
  #
  # @param map [Map]
  # @return [Map]
  def named(map)
    people = ::Person.where(tenant_id: @plan.tenant_id, id: map.person_ids).pluck(:id, :name).to_h
    hires = map.people.select(&:placeholder?).to_h { [ it.id, it.placeholder.removed? ? PLACEHOLDER_NAME : it.placeholder.reveal ] }
    map.with(names: people.merge(hires), positions: named_positions(map.positions))
  end

  private

  # Configuration, so every day a reader asks for reads the lines as the plan is priced with them.
  def approved_budget = @approved_budget ||= inputs.budget_lines.map { BudgetLine.approved(it) }

  def inputs = @inputs ||= TeamPlanning::PricingInputs.for(@plan)

  # The set is the baseline's on every day a reader asks for, so a later
  # read can neither drop a line the plan holds nor reach one it doesn't.
  def held_on(date, as_known, map, units)
    return structure.held_cost_centres unless date == @plan.base_on && as_known == known_on

    baseline_cost_centres(map, units)
  end

  # What a scoped plan's seats can draw on, as the Org Graph stands
  # ([#378](https://github.com/espaliahq/espalia/issues/378)): the real cost
  # centre of each person in scope, and each the tenant's cost centre entries
  # can give a seat there. That is an entry naming a covered unit or one
  # above it, or no unit, since a seat in scope can match its role, level or
  # location. A plan's own rules and labels never widen it.
  def baseline_cost_centres(map, units)
    parents = units.to_h { [ it.id, it.parent_id ] }
    reach = Set.new
    map.units.each do |unit|
      id = unit.id
      id = parents[id] while id && reach.add?(id)
    end
    entries = TeamPlanning::RuleKinds::CostCentre.entries(map.rules.value_of("cost_centre", along: []))
    map.people.filter_map { it.cost_centre.presence } + entries.filter_map { it["cost_centre"] if it["unit_id"].nil? || reach.include?(it["unit_id"]) }
  end

  def named_positions(positions)
    return positions if positions.empty?

    roles = FrameworkState::Role.where(tenant_id: @plan.tenant_id, role_id: positions.map(&:role_id).uniq).pluck(:role_id, :name).to_h
    levels = FrameworkState::Level.where(tenant_id: @plan.tenant_id, level_id: positions.map(&:level_id).uniq).pluck(:level_id, :title).to_h
    positions.map { it.with(role_name: roles[it.role_id], level_name: levels[it.level_id]) }
  end

  def person_from(person, memberships)
    places = memberships.map { Membership.new(**it.to_h.slice(*Membership.members)) }
    Member.new(**person.to_h.slice(*Member.members), memberships: places)
  end
end
