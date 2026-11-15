# frozen_string_literal: true

# What each change in effect in a scenario would need to move into an agreed
# part alone ([#360](https://github.com/espaliahq/espalia/issues/360)), read
# before anyone splits. The aggregate's own stands-alone check answers it,
# over the same parent map {TeamPlanning::CommandHandler#split_scenario}
# reads, so a choice this reads as standing alone splits.
#
# @example
#   TeamPlanning::SplitNeeds.new(context:, plan:, scenario_id:).call.changes
class TeamPlanning::SplitNeeds
  # @!attribute changes [Array<Change>] the latest change per subject and facet, oldest first
  # @!attribute names [Hash{String => String}] subject id => name, as status names them
  Report = Data.define(:changes, :names)

  # @!attribute event_id [String] the change to name when splitting
  # @!attribute needs [Array<Need>] the staying changes it can't go across without
  Change = Data.define(:event_id, :subject_id, :facet, :needs)

  # @!attribute event_id [String, nil] the change in effect to move across with it; nil when none is, so this
  #   change can't move at all
  Need = Data.define(:event_id, :subject_id, :facet)

  # The ids the scenario's parent resolves to, which a moving change may need
  # without anything moving with it.
  #
  # @param context [AuthorizationContext]
  # @param aggregate [TeamPlanning::PlanAggregate]
  # @param scenario_id [String]
  # @return [Set<String>] units, positions and people
  def self.standing_ids(context:, aggregate:, scenario_id:)
    parent_id = aggregate.scenarios[scenario_id]&.parent_id or return Set.new

    map = TeamPlanning::Resolution.new(context:, plan: TeamPlanningPlan.find(aggregate.plan_id), scenario_id: parent_id).structure(aggregate)
    [ map.units, map.positions, map.people ].flatten.to_set(&:id)
  end

  # @param context [AuthorizationContext]
  # @param plan [TeamPlanningPlan]
  # @param scenario_id [String] a live scenario
  # @param repository [TeamPlanning::Repository]
  def initialize(context:, plan:, scenario_id:, repository: TeamPlanning::Repository.new)
    @context = context
    @plan = plan
    @scenario_id = scenario_id
    @repository = repository
  end

  # @return [Report]
  # @raise [Pundit::NotAuthorizedError] when the caller can't open the plan
  # @raise [TeamPlanning::Error] when the scenario is unknown or the baseline, or the plan is gone
  def call
    Pundit.authorize(@context, @plan, :show?, policy_class: PlanPolicy)
    aggregate = @repository.load_plan(@plan.id)
    needs = aggregate.split_needs(@scenario_id, standing_ids: self.class.standing_ids(context: @context, aggregate:, scenario_id: @scenario_id))
    in_effect = needs.keys.to_h { [ it.key, it.event_id ] }
    changes = needs.map do |change, blocks|
      subject_id, facet = change.key
      Change.new(event_id: change.event_id, subject_id:, facet:, needs: blocks.uniq { [ it.subject_id, it.facet ] }.map do
        Need.new(event_id: in_effect[[ it.subject_id, it.facet ]], subject_id: it.subject_id, facet: it.facet)
      end)
    end
    Report.new(changes:, names: names_of(changes))
  end

  private

  def names_of(changes)
    return {} if changes.empty?

    ids = changes.flat_map { [ it.subject_id, *it.needs.map(&:subject_id) ] }
    TeamPlanning::Status.new(context: @context, plan: @plan, scenario_id: @scenario_id, repository: @repository).call.names.slice(*ids)
  end
end
