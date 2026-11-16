# frozen_string_literal: true

# What updating a plan to today would take in, read before a planner
# confirms: the drift for the window ({TeamPlanning::Drift}), where each
# scenario's changes stand ({TeamPlanning::Status}), and the conflicts the
# update would carry forward, all read over one base.
#
# Once the base is today, today reads the base, so a conflicting change would
# read pending. {#call} names each conflict so the update can record it.
#
# @example
#   TeamPlanning::RebasePreview.new(context:, plan:).call.conflicts
class TeamPlanning::RebasePreview
  # @!attribute base_on [Date] where the plan stands now
  # @!attribute to [Date] today, the base it would move to
  # @!attribute scenarios [Array<Counts>] the baseline first, then each live scenario
  # @!attribute conflicts [Array<Hash>] `{ scenario_id, subject_id, facet, change_id }`: the scenario it reads conflicting in, and the change that scenario resolves to
  # @!attribute drift [TeamPlanning::Drift::Report] what the Org Graph learned in the window
  # @!attribute names [Hash{String => String}] subject id => name for each conflict's subject, as status names it
  # @!attribute starts [Array<Hash>] `{ scenario_id, starts_on, will_start_on }`: the first step whose start the
  #   update moves to today, if any. One that starts after today keeps its start.
  Report = Data.define(:base_on, :to, :scenarios, :conflicts, :drift, :names, :starts)

  # @!attribute scenario_id [String] the plan's id for the baseline
  Counts = Data.define(:scenario_id, :done, :pending, :conflicting)

  # @param context [AuthorizationContext]
  # @param plan [TeamPlanningPlan]
  # @param today [Date] as a UTC date
  # @param repository [TeamPlanning::Repository]
  def initialize(context:, plan:, today: Time.now.utc.to_date, repository: TeamPlanning::Repository.new)
    @context = context
    @plan = plan
    @today = today
    @repository = repository
  end

  # @return [Report]
  # @raise [Pundit::NotAuthorizedError] when the caller can't open the plan or see the Org Graph
  # @raise [TeamPlanning::Error] when the plan already stands on today, or on a day still to come, or is
  #   updated while the preview reads it, or when its first step would end before today or a step is closed
  def call
    Pundit.authorize(@context, @plan, :show?, policy_class: PlanPolicy)
    @plan.reload
    raise TeamPlanning::Error, "This plan already stands on today, #{@today.iso8601}" if @plan.base_on == @today
    if @plan.base_on > @today
      raise TeamPlanning::Error, "This plan stands on #{@plan.base_on.iso8601}, still to come: it already reads the Org Graph as known now"
    end

    base_on = @plan.base_on
    aggregate = @repository.load_plan(@plan.id)
    raise TeamPlanning::Error, TeamPlanning::PlanAggregate::CLOSED_REBASE if aggregate.closed_steps.any?

    aggregate.ensure_first_steps_reach!(@today)
    starts = aggregate.first_step_starts(@today).map { |id, before, after| { scenario_id: id, starts_on: before, will_start_on: after } }
    drift = TeamPlanning::Drift.new(context: @context, plan: @plan, today: @today, repository: @repository).call
    reports = scenario_ids.map { [ it, status_of(it) ] }
    raise TeamPlanning::Error, "This plan was updated while you looked: preview it again" unless @plan.base_on == base_on

    conflicts = reports.flat_map { |id, report| conflicts(id, report) }
    names = reports.map { it.last.names }.reduce({}, :merge).slice(*conflicts.map { it[:subject_id] })
    Report.new(base_on:, to: @today, scenarios: reports.map { |id, report| counts(id, report) }, conflicts:, drift:, names:, starts:)
  end

  private

  def scenario_ids = [ @plan.id, *@repository.load_plan(@plan.id).scenarios.keys ]

  def status_of(scenario_id) = TeamPlanning::Status.new(context: @context, plan: @plan, scenario_id:, today: @today, repository: @repository).call

  def counts(scenario_id, report)
    tally = report.statuses.map(&:status).tally
    Counts.new(scenario_id:, done: tally.fetch(:done, 0), pending: tally.fetch(:pending, 0), conflicting: tally.fetch(:conflicting, 0))
  end

  def conflicts(scenario_id, report)
    report.statuses.select { it.status == :conflicting }.map { { scenario_id:, subject_id: it.subject_id, facet: it.facet, change_id: it.change_id } }
  end
end
