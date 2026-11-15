# frozen_string_literal: true

# One scenario's organisation, resolved and never stored: the plan's
# {TeamPlanning::Baseline}, then the changes of each scenario along the
# scenario's {TeamPlanning::PlanAggregate#resolution_chain}. The last change
# for a subject and facet wins, so changes to different facets never compete.
#
# Like the baseline, {#structure} is ids only and {#call} joins the names last.
#
# @example
#   TeamPlanning::Resolution.new(context:, plan:, scenario_id: lean_q1).call
class TeamPlanning::Resolution
  # @param context [AuthorizationContext]
  # @param plan [TeamPlanningPlan]
  # @param scenario_id [String] the plan's id for the root
  # @param repository [TeamPlanning::Repository]
  # @param base [TeamPlanning::Baseline::Map, nil] the plan's baseline, already
  #   read by a caller resolving several scenarios over the same one
  def initialize(context:, plan:, scenario_id:, repository: TeamPlanning::Repository.new, base: nil)
    @baseline = TeamPlanning::Baseline.new(context:, plan:)
    @context = context
    @base = base
    @plan = plan
    @scenario_id = scenario_id
    @repository = repository
  end

  # @param aggregate [TeamPlanning::PlanAggregate] the plan as loaded
  # @return [TeamPlanning::Baseline::Map] with names joined
  # @raise [Pundit::NotAuthorizedError] when the caller can't open the plan or see the Org Graph
  # @raise [TeamPlanning::Error] for a scenario the plan doesn't have
  def call(aggregate = @repository.load_plan(@plan.id)) = @baseline.named(structure(aggregate))

  # @param aggregate [TeamPlanning::PlanAggregate] the plan as loaded; a write
  #   passes the one it holds under the lock
  # @return [TeamPlanning::Baseline::Map] by id, with no names
  # @raise [Pundit::NotAuthorizedError] when the caller can't open the plan or see the Org Graph
  # @raise [TeamPlanning::Error] for a scenario the plan doesn't have
  def structure(aggregate = @repository.load_plan(@plan.id)) = resolved(aggregate).first

  # @return [Array<TeamPlanning::Attention::Item>] what no longer fits, each with the change it belongs to
  # @raise [Pundit::NotAuthorizedError] when the caller can't open the plan or see the Org Graph
  # @raise [TeamPlanning::Error] for a scenario the plan doesn't have
  def attention
    aggregate = @repository.load_plan(@plan.id)
    map, changes = resolved(aggregate)
    capacity = TeamPlanning::Capacity.new(context: @context, plan: @plan, scenario_id: @scenario_id, repository: @repository)
                                     .report_for(map)
    TeamPlanning::Attention.new(map, changes, left_ids: left_since(map), closed_units: closed_position_units(aggregate, changes),
                                              unclassified: capacity.configured? ? capacity.unclassified : []).call
  end

  private

  def resolved(aggregate = @repository.load_plan(@plan.id))
    winning = @repository.sealed(aggregate.winning_changes(@scenario_id))
    base = (@base || @baseline.structure).with(step_ids: step_of(aggregate))
    hires, others = winning.values.partition { it.is_a?(TeamPlanning::Events::PlaceholderSet) }
    map = (hires + others).reduce(base) { |resolved, change| change.class.apply_to(resolved, change.data) }
    [ explained(map.settled), winning ]
  end

  # A closed position is off the map, so its unit comes from the last
  # PositionSet the chain made for it.
  def closed_position_units(aggregate, winning)
    closed = winning.values.select { it.is_a?(TeamPlanning::Events::PositionClosed) }.to_set { it.data[:subject_id] }
    return {} if closed.empty?

    aggregate.resolution_chain(@scenario_id).flat_map { aggregate.changes_in(it) }
             .select { it.is_a?(TeamPlanning::Events::PositionSet) && closed.include?(it.data[:subject_id]) }
             .to_h { [ it.data[:subject_id], it.data[:unit_id] ] }
  end

  # The scenario and those it is an alternative of: the chain after the step
  # before it on the timeline. The scenarios that step replaced come earlier
  # in the chain, so they drop off too.
  def step_of(aggregate)
    chain = aggregate.resolution_chain(@scenario_id)
    before = aggregate.timeline_path(@scenario_id)[-2]
    step = before ? chain.drop(chain.index(before) + 1) : chain
    (step + aggregate.resting_on(@scenario_id)).uniq
  end

  # The people on the map the Org Graph has had leave by today, a UTC day.
  def left_since(map)
    OrgLeaver.where(tenant_id: @plan.tenant_id, person_id: map.people.map(&:id), left_on: ..Time.now.utc.to_date).pluck(:person_id)
  end

  # A person off the map either left by the base date, or was forgotten, or
  # joined after it.
  def explained(map)
    return map if map.unresolved.empty?

    ids = map.unresolved.map(&:person_id)
    left = OrgLeaver.where(tenant_id: @plan.tenant_id, person_id: ids).where(left_on: ..map.base_on).pluck(:person_id) +
           ::Person.where(tenant_id: @plan.tenant_id, id: ids).where.not(forgotten_at: nil).pluck(:id)
    map.with(unresolved: map.unresolved.map { it.with(why: left.include?(it.person_id) ? it.class::LEFT : it.class::JOINED_LATER) })
  end
end
