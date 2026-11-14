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
# - **conflicting**: today reads none of these.
#
# A plan whose base is still to come holds every change against today, so
# nothing it plans reads conflicting before the plan starts.
#
# Only a kind that reads its end state off a map
# ({TeamPlanning::Events::Change.readable?}) and that the Org Graph can move
# ({TeamPlanning::Events::Change.subject_moved_by}) has a status. A plan-only
# kind, such as a rule, would read pending forever, so it is left out. Today's
# map holds the units the Org Graph retired and its successions, read through
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
  # @!attribute status [Symbol] :done, :pending or :conflicting
  Entry = Data.define(:scenario_id, :change_id, :subject_id, :facet, :status)

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
    @aggregate = @repository.load_plan(@plan.id)
    @resolved = {}
    changes = tracked_changes
    return Report.new(on: @today, statuses: [], names: {}) if changes.empty?

    now = @baseline.map_on(@today, history: true)
    base = @today < @plan.base_on ? now : @baseline.structure
    statuses = changes.map { |key, change| entry(change, key, base:, now:) }
    Report.new(on: @today, statuses:, names: names_for(statuses.map(&:subject_id), base, now))
  end

  private

  def tracked_changes
    @aggregate.winning_changes(@scenario_id).select { |_, change| change.class.readable? && change.class.meets_org_graph? }
  end

  def entry(change, key, base:, now:)
    kind = change.class
    subject_id, facet = key
    today = kind.read_org_graph(now, change)
    before = [ [ kind.read_org_graph(base, change), base ], *step_before(change, key, base) ]
    Entry.new(scenario_id: change.data[:scenario_id], change_id: change.event_id, subject_id:, facet:,
              status: status_of(kind, today, [ end_state_of(change), resolved(@scenario_id) ], before))
  end

  # Each planned state comes with the map it belongs to, so a kind can show it as the Org Graph would.
  def status_of(kind, today, planned, before)
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
    earlier = @aggregate.winning_changes(path[index - 1])[key] if index.positive?
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
