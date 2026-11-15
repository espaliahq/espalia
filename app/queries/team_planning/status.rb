# frozen_string_literal: true

# Where each of a scenario's planned changes stands against the Org Graph
# today, read by comparison every time and never stored. For each subject and
# facet the scenario resolves, down its resolution chain, the winning
# change's end state is held against two maps in the baseline's shape: today's
# organisation, as known now, and the plan's baseline.
#
# - **done**: today reads the end state;
# - **pending**: today still reads what the baseline held, or what the step
#   before the change's own step plans;
# - **conflicting**: today reads none of these;
# - **unknown**: the plan's value is sealed and its key is gone, so nobody can
#   say what it planned.
# - **plan_only**: the Org Graph never holds what it plans, such as a rule, a
#   position, a hire the plan adds or a person's pay, so it is never compared.
#
# A plan whose base is still to come holds every change against today, so
# nothing it plans reads conflicting before the plan starts.
#
# Once a plan is updated to today, today reads its base, so a change that
# conflicted would read pending. A conflict the update carried forward in this
# scenario ({TeamPlanning::PlanAggregate#carried_conflicts}) reads conflicting,
# with `since` the day of the update that first found it, while the scenario
# still resolves to the same change. A change that reads done reads done.
#
# Only a change the Org Graph can show is compared
# ({TeamPlanning::Events::Change.tracks?}); held against it, a plan-only one
# would read pending forever. Today's map holds the units
# the Org Graph retired, its successions and the people who left, read through
# {TeamPlanning::Events::Change.read_org_graph}, since a succession there has
# an id the plan never saw.
#
# Each kind compares with {TeamPlanning::Events::Change.shows?}, given the
# map its planned state settles on, since the Org Graph can't say which
# position someone fills, only where they are.
#
# @example
#   TeamPlanning::Status.new(context:, plan:, scenario_id:).call.statuses.select { it.status == :conflicting }
class TeamPlanning::Status
  # @!attribute on [Date] today
  # @!attribute statuses [Array<Entry>] in the order the changes land
  # @!attribute names [Hash{String => String}] subject id => name, for the people and units the Org Graph holds
  Report = Data.define(:on, :statuses, :names) do
    # @param subject_id [String]
    # @return [String, nil] nil for a subject only the plan holds
    def name_of(subject_id) = names[subject_id]
  end

  # @!attribute scenario_id [String] the scenario that made the change, the plan's id for the root
  # @!attribute change_id [String] the planned change's event id
  # @!attribute subject_id [String]
  # @!attribute facet [String]
  # @!attribute status [Symbol] one of {STATUSES}
  # @!attribute since [Date, nil] for a conflict an update to today carried forward, the day of that update
  # @!attribute sources [Array<String>] who supplies what it moves, from {TeamPlanning::SourceOfTruth}
  Entry = Data.define(:scenario_id, :change_id, :subject_id, :facet, :status, :since, :sources)

  STATUSES = %i[done pending conflicting unknown plan_only].freeze

  # @param context [AuthorizationContext]
  # @param plan [TeamPlanningPlan]
  # @param scenario_id [String] the plan's id for the root
  # @param today [Date] as a UTC date
  # @param repository [TeamPlanning::Repository]
  def initialize(context:, plan:, scenario_id:, today: Time.now.utc.to_date, repository: TeamPlanning::Repository.new)
    @baseline = TeamPlanning::Baseline.new(context:, plan:)
    @context = context
    @plan = plan
    @scenario_id = scenario_id
    @today = today
    @repository = repository
  end

  # @return [Report]
  # @raise [Pundit::NotAuthorizedError] when the caller can't open the plan or see the Org Graph
  # @raise [TeamPlanning::Error] for a scenario the plan doesn't have
  def call
    Pundit.authorize(@context, @plan, :show?, policy_class: PlanPolicy)
    @plan.reload
    @aggregate = @repository.load_plan(@plan.id)
    @carried = @aggregate.carried_conflicts(@scenario_id)
    @resolved = {}
    @winning = {}
    changes = winning(@scenario_id)
    return Report.new(on: @today, statuses: [], names: {}) if changes.empty?

    tracked = tracked(changes)
    now, base = maps
    units = tracked.to_h { |key, change| [ key, units_of(change, key, now) ] }
    @sources = TeamPlanning::SourceOfTruth.new(tenant_id: @plan.tenant_id).preload(unit_ids: units.values.flatten)
    statuses = changes.map do |key, change|
      tracked.key?(key) ? entry(change, key, base:, now:, unit_ids: units[key]) : plan_only(change, key)
    end
    Report.new(on: @today, statuses:, names: names_for(statuses.map(&:subject_id), base, now))
  end

  private

  # A placeholder hire never reaches the Org Graph, so nothing it holds is compared.
  def tracked(changes)
    hires = changes.keys.filter_map { |subject_id, facet| subject_id if facet == TeamPlanning::Events::PlaceholderSet.facet }
    changes.select { |(subject_id, _), change| change.class.tracks?(change) && hires.exclude?(subject_id) }
  end

  def plan_only(change, (subject_id, facet))
    Entry.new(scenario_id: change.data[:scenario_id], change_id: change.event_id, subject_id:, facet:, status: :plan_only, since: nil, sources: [])
  end

  # Today, and the base to hold it against. A succession the Org Graph held on
  # the base date came before the plan, so today leaves it out. Both read the
  # whole organisation, as a change can move someone out of the plan's scope.
  def maps
    now = @baseline.map_on(@today, history: true, scoped: false)
    return [ now, now ] if @today < @plan.base_on

    base = @baseline.map_on(@plan.base_on, known_on: @plan.base_on - 1, history: true, scoped: false)
    [ now.with(successions: now.successions - base.successions), base.with(retired_units: [], successions: [], left_ids: []) ]
  end

  def winning(scenario_id) = @winning[scenario_id] ||= @repository.sealed(@aggregate.winning_changes(scenario_id))

  def entry(change, key, base:, now:, unit_ids:)
    kind = change.class
    subject_id, facet = key
    today = kind.read_org_graph(now, change)
    before = [ [ kind.read_org_graph(base, change), base ], *step_before(change, key, base) ]
    status = status_of(kind, today, [ end_state_of(change), resolved(@scenario_id) ], before)
    since = @carried[key] unless %i[done unknown].include?(status)
    Entry.new(scenario_id: change.data[:scenario_id], change_id: change.event_id, subject_id:, facet:,
              status: since ? :conflicting : status, since:, sources: @sources.of_plan(facet, unit_ids:))
  end

  # A move touches the units someone is in today, the ones the scenario places
  # them in, and the ones it names, as someone the Org Graph lacks is in neither map.
  def units_of(change, key, now)
    subject_id, facet = key
    case facet
    when TeamPlanning::Events::AssignmentSet.facet
      maps = [ now, resolved(@scenario_id) ]
      maps.flat_map { |map| people_of(map)[subject_id]&.memberships.to_a.map(&:unit_id) } + placed_units(change)
    when TeamPlanning::Events::UnitSuccessionSet.facet then change.data.values_at(:predecessor_ids, :successor_ids).flatten.compact
    when TeamPlanning::Events::UnitSet.facet then [ subject_id ]
    else []
    end
  end

  def placed_units(change)
    positions = units_of_positions(resolved(@scenario_id))
    change.data[:placements].to_a.map { it.to_h.symbolize_keys }.map { it[:unit_id] || positions[it[:position_id]] }
  end

  def units_of_positions(map) = (@position_units ||= {}.compare_by_identity)[map] ||= map.positions.to_h { [ it.id, it.unit_id ] }

  def people_of(map) = (@people ||= {}.compare_by_identity)[map] ||= map.people.index_by(&:id)

  def removed?(end_state) = end_state.values.any? { it.is_a?(Shreddable::Value) && it.removed? }

  # Each planned state comes with the map it belongs to, so a kind can show it as the Org Graph would.
  def status_of(kind, today, planned, before)
    return :unknown if removed?(planned.first)
    return :done if kind.shows?(today, planned.first, map: planned.last)

    before.any? { |state, map| kind.shows?(today, state, map:) } ? :pending : :conflicting
  end

  def resolved(scenario_id)
    @resolved[scenario_id] ||= TeamPlanning::Resolution.new(context: @context, plan: @plan, scenario_id:, repository: @repository).structure
  end

  def end_state_of(change) = change.data.except(*TeamPlanning::Events::Change::FIELDS)

  # What the step before the change's own step plans for its key, if it plans anything. Another
  # kind on the facet is read as the change's own kind reads it, so a retirement before a
  # restoration reads as no unit. An
  # alternative takes its parent's place on the timeline, so a change it
  # inherits lands at the alternative's step.
  def step_before(change, key, base)
    path = @aggregate.timeline_path(@scenario_id)
    chain = @aggregate.resolution_chain(@scenario_id)
    step = chain.drop(chain.index(change.data[:scenario_id])).find { path.include?(it) }
    index = path.index(step)
    earlier = winning(path[index - 1])[key] if index.positive?
    return [] unless earlier
    return [ [ end_state_of(earlier), resolved(path[index - 1]) ] ] if earlier.instance_of?(change.class)

    subject_id, facet = key
    [ [ change.class.read_from(earlier.class.apply_to(base, earlier.data), subject_id:, facet:), base ] ]
  end

  # Today's name wins; the base names a unit since retired.
  def names_for(ids, *maps)
    units = maps.flat_map { it.units + it.retired_units }.to_h { [ it.id, it.name ] }
    people = ::Person.where(tenant_id: @plan.tenant_id, id: ids.uniq).pluck(:id, :name).to_h
    units.slice(*ids).merge(people)
  end
end
