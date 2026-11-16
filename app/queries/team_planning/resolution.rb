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
    winning = @repository.sealed(aggregate.winning_changes(@scenario_id))
    base = (@base || @baseline.structure).with(step_ids: step_of(aggregate))
    hires, others = winning.values.partition { it.is_a?(TeamPlanning::Events::PlaceholderSet) }
    map = (hires + others).reduce(base) { |resolved, change| change.class.apply_to(resolved, change.data) }
    [ explained(stepped(opened(map.settled, aggregate), aggregate)), winning ]
  end

  # Each position's open date: the first day of the earliest step in the
  # chain that sets it since it last closed, or the base date when the plan's
  # Today sets it. A seat open since before the plan began is never taken as
  # already filled ([#458](https://github.com/espaliahq/espalia/issues/458)).
  #
  # @param aggregate [TeamPlanning::PlanAggregate]
  # @param scenario_id [String] a scenario, or the plan's id for Today
  # @return [Hash{String => Date}] by position id
  def self.opened_on(aggregate, scenario_id)
    aggregate.resolution_chain(scenario_id).each_with_object({}) do |id, opened|
      aggregate.changes_in(id).each do |change|
        case change
        when TeamPlanning::Events::PositionSet then opened[change.data[:subject_id]] ||= aggregate.period_of(id)&.begin || aggregate.base_on
        when TeamPlanning::Events::PositionClosed then opened.delete(change.data[:subject_id])
        end
      end
    end
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

  private

  # The scenario and those it is an alternative of: the chain after the step
  # before it on the timeline. The scenarios that step replaced come earlier
  # in the chain, so they drop off too.
  def step_of(aggregate)
    chain = aggregate.resolution_chain(@scenario_id)
    before = aggregate.timeline_path(@scenario_id)[-2]
    step = before ? chain.drop(chain.index(before) + 1) : chain
    (step + aggregate.resting_on(@scenario_id)).uniq
  end

  # A backfill whose leaver went in an earlier step opens no earlier than the
  # day after they left, or the first day of the step they left in when the
  # plan gave no date. A leaver still on this step's map holds their own seat,
  # and cost opens it the day after they go.
  def opened(map, aggregate)
    return map if map.positions.empty?

    dates = self.class.opened_on(aggregate, @scenario_id)
    vacated = map.departed.select(&:position_id).group_by(&:position_id).transform_values do |gone|
      gone.map { TeamPlanning::Events::DepartureSet.leaving_date(it.leaves_on)&.next_day || aggregate.period_of(it.leaves_in_id)&.begin }.compact.max
    end
    map.with(positions: map.positions.map { it.with(opened_on: [ dates.fetch(it.id, aggregate.base_on), vacated[it.id] ].compact.max) })
  end

  # Today runs for a year from the base date, as its run rate does.
  def stepped(map, aggregate)
    period = TeamPlanning::FiguredPeriod.for(aggregate, @scenario_id, map)&.period || TeamPlanning::Cost.year_from(aggregate.base_on)
    map.with(step: period)
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
