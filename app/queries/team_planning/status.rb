# frozen_string_literal: true

# Where each of a scenario's planned changes stands against the Org Graph
# today, read by comparison every time and never stored. For each subject and
# facet the scenario resolves, down its resolution chain, the winning
# change's end state is held against two maps in the baseline's shape: today's
# organisation, as known now, and the plan's baseline.
#
# - **done**: today reads the end state;
# - **pending**: today still reads what the baseline held;
# - **conflicting**: today reads neither.
#
# Only a kind that reads its end state off a map
# ({TeamPlanning::Events::Change.readable?}) and that the Org Graph can move
# ({TeamPlanning::Events::Change.subject_moved_by}) has a status. A plan-only
# kind, such as a rule, would read pending forever, so it is left out.
#
# @example
#   TeamPlanning::Status.new(context:, plan:, scenario_id:).call.statuses.select { it.status == :conflicting }
class TeamPlanning::Status
  STATUSES = %i[done pending conflicting].freeze

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
    changes = tracked_changes
    return Report.new(on: @today, statuses: [], names: {}) if changes.empty?

    base = @baseline.structure
    now = @baseline.map_on(@today)
    statuses = changes.map { |facet, change| entry(change, facet, base:, now:) }
    Report.new(on: @today, statuses:, names: names_for(statuses.map(&:subject_id), base, now))
  end

  private

  def tracked_changes
    @repository.load_plan(@plan.id).winning_changes(@scenario_id).filter_map do |(_, facet), change|
      [ facet, change ] if change.class.readable? && change.class.meets_org_graph?
    end
  end

  def entry(change, facet, base:, now:)
    kind = change.class
    subject_id = change.data[:subject_id]
    planned = change.data.except(*TeamPlanning::Events::Change::FIELDS)
    today = kind.read_from(now, subject_id:, facet:)
    Entry.new(scenario_id: change.data[:scenario_id], change_id: change.event_id, subject_id:, facet:,
              status: status_of(today, planned, kind.read_from(base, subject_id:, facet:)))
  end

  def status_of(today, planned, base)
    return :done if same?(today, planned)

    same?(today, base) ? :pending : :conflicting
  end

  # A stored end state and one read off a map can differ in key type alone.
  def same?(left, right) = left.as_json == right.as_json

  # Today's name wins; the base names a unit since retired.
  def names_for(ids, *maps)
    units = maps.flat_map(&:units).to_h { [ it.id, it.name ] }
    people = ::Person.where(tenant_id: @plan.tenant_id, id: ids.uniq).pluck(:id, :name).to_h
    units.slice(*ids).merge(people)
  end
end
