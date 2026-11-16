# frozen_string_literal: true

# One scenario's organisation, resolved and never stored: the plan's
# {TeamPlanning::Baseline}, then the changes of each scenario along the
# scenario's {TeamPlanning::PlanAggregate#resolution_chain}. The last change
# for a subject and facet wins, so changes to different facets never compete.
#
# A scenario after a closed step stands on the Org Graph the day after that
# step ends instead ({TeamPlanning::PlanAggregate#standing_after}). The
# changes the closed steps made that the Org Graph then held drop away, and
# the rest carry over, so it reads as a first step from that day would.
#
# Like the baseline, {#structure} is ids only and {#call} joins the names last.
#
# @example
#   TeamPlanning::Resolution.new(context:, plan:, scenario_id: lean_q1).call
class TeamPlanning::Resolution
  # A scenario resolved for one viewer, with the baseline it rests on, so a
  # reader in the same request can price it instead of resolving it again.
  # Its key holds what the resolution depended on, as {#call}'s cache key does.
  Shared = Data.define(:key, :base, :map) do
    # @param context [AuthorizationContext]
    # @param plan [TeamPlanningPlan]
    # @param scenario_id [String]
    # @return [Array]
    def self.key(context, plan, scenario_id) = [ *CurrentPlanReads.viewer(context), plan.id, plan.base_on, plan.archived_on, scenario_id ]

    # @return [Shared] self, when it was resolved for this viewer, plan and scenario
    # @raise [ArgumentError] otherwise, as a map resolved for someone else could price what this viewer can't see
    def for!(context, plan, scenario_id)
      return self if key == Shared.key(context, plan, scenario_id)

      raise ArgumentError, "This map was resolved for another viewer, plan or scenario"
    end

    # @param baseline [TeamPlanning::Baseline] the plan's, to join the names
    # @return [TeamPlanning::Baseline::Map] the map with names, as {Resolution#call} gives and caches it
    def named(baseline) = CurrentPlanReads.fetch([ :scenario, *key ]) { baseline.named(map) }
  end

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
  def call(aggregate = nil)
    CurrentPlanReads.fetch([ :scenario, *Shared.key(@context, @plan, @scenario_id) ]) do
      @baseline.named(structure(aggregate || @repository.load_plan(@plan.id)))
    end
  end

  # Reuses every scenario and baseline read inside the block, so a page that
  # shows a scenario's map and prices it, beside the baseline's, reads the
  # Org Graph once. A plan write empties it ({TeamPlanning::Repository#with_plan}).
  #
  # @yield the unit of work
  # @return [Object] what the block returns
  def self.reusing
    return yield if CurrentPlanReads.memo

    begin
      CurrentPlanReads.memo = {}
      yield
    ensure
      CurrentPlanReads.memo = nil
    end
  end

  # @param aggregate [TeamPlanning::PlanAggregate] the plan as loaded; a write
  #   passes the one it holds under the lock
  # @return [TeamPlanning::Baseline::Map] by id, with no names
  # @raise [Pundit::NotAuthorizedError] when the caller can't open the plan or see the Org Graph
  # @raise [TeamPlanning::Error] for a scenario the plan doesn't have
  def structure(aggregate = @repository.load_plan(@plan.id)) = resolved(aggregate).first

  # {#resolved}, kept with its baseline for another reader to price.
  #
  # @param aggregate [TeamPlanning::PlanAggregate]
  # @return [Array(Shared, Hash{Array(String, String) => TeamPlanning::Events::Change})]
  # @raise [Pundit::NotAuthorizedError] when the caller can't open the plan or see the Org Graph
  # @raise [TeamPlanning::Error] for a scenario the plan doesn't have
  def shared(aggregate)
    @base ||= @baseline.structure
    map, winning = resolved(aggregate)
    [ Shared.new(key: Shared.key(@context, @plan, @scenario_id), base: @base, map:), winning ]
  end

  # @param map [TeamPlanning::Baseline::Map] from {#resolved}
  # @return [TeamPlanning::Baseline::Map] with names joined, as {#call} gives it
  def named(map) = @baseline.named(map)

  # @param aggregate [TeamPlanning::PlanAggregate]
  # @return [Array(TeamPlanning::Baseline::Map, Hash{Array(String, String) => TeamPlanning::Events::Change})]
  #   the settled map by id, and the winning changes by key
  # @raise [Pundit::NotAuthorizedError] when the caller can't open the plan or see the Org Graph
  # @raise [TeamPlanning::Error] for a scenario the plan doesn't have
  def resolved(aggregate = @repository.load_plan(@plan.id))
    standing = aggregate.standing_after(@scenario_id)
    winning = @repository.sealed(aggregate.winning_changes(@scenario_id))
    winning = winning.reject { |_, change| done_at_close(*standing).include?(change.event_id) } if standing
    base = (standing ? standing_on(standing.last) : @base || @baseline.structure).with(step_ids: step_of(aggregate))
    hires, others = winning.values.partition { it.is_a?(TeamPlanning::Events::PlaceholderSet) }
    map = (hires + others).reduce(base) { |resolved, change| change.class.apply_to(resolved, change.data) }
    [ explained(map.settled), winning ]
  end

  # @param map [TeamPlanning::Baseline::Map]
  # @return [Array<String>] the people on the map the Org Graph has had leave by today, a UTC day
  def left_since(map)
    OrgLeaver.where(tenant_id: @plan.tenant_id, person_id: map.people.map(&:id), left_on: ..Time.now.utc.to_date).pluck(:person_id)
  end

  # A closed position is off the map, so its unit comes from the last
  # PositionSet the chain made for it.
  #
  # @param aggregate [TeamPlanning::PlanAggregate]
  # @param winning [Hash{Array(String, String) => TeamPlanning::Events::Change}]
  # @return [Hash{String => String}] each closed position's unit, by position id
  def closed_position_units(aggregate, winning)
    closed = winning.values.select { it.is_a?(TeamPlanning::Events::PositionClosed) }.to_set { it.data[:subject_id] }
    return {} if closed.empty?

    aggregate.resolution_chain(@scenario_id).flat_map { aggregate.changes_in(it) }
             .select { it.is_a?(TeamPlanning::Events::PositionSet) && closed.include?(it.data[:subject_id]) }
             .to_h { [ it.data[:subject_id], it.data[:unit_id] ] }
  end

  # The changes a closed step and those before it made that the Org Graph
  # held the day after it ended, as {TeamPlanning::Status} reads them. A step
  # after it stands on that day's organisation, so they drop away; every
  # other change carries over and lands again. An archived plan reads them as
  # the Org Graph knew them on its archive day, so a fact recorded later moves nothing.
  #
  # @param closed_id [String] the step closed
  # @param ends_on [Date] its last day
  # @return [Set<String>] their event ids
  def done_at_close(closed_id, ends_on)
    CurrentPlanReads.fetch([ :done_at_close, *CurrentPlanReads.viewer(@context), @plan.id, @plan.base_on, @plan.archived_on, closed_id, ends_on ]) do
      TeamPlanning::Status.new(context: @context, plan: @plan, scenario_id: closed_id, today: ends_on + 1, known_on: @plan.archived_on,
                               repository: @repository)
                          .call.statuses.select { it.status == :done }.to_set(&:change_id)
    end
  end

  private

  # The organisation the day after a closed step ends, known now, or on the
  # archive day once the plan is archived.
  def standing_on(ends_on)
    CurrentPlanReads.fetch([ :standing, *CurrentPlanReads.viewer(@context), @plan.id, @plan.archived_on, ends_on ]) do
      @baseline.map_on(ends_on + 1, known_on: @plan.archived_on)
    end
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
