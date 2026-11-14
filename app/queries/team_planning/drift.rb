# frozen_string_literal: true

# What the Org Graph has learned since a plan's base: {OrgGraph::ChangesBetween}
# by learned date, from the day before the base date, as the baseline reads
# it, to today. Each change says which of the plan's own changes it meets, by
# scenario, and whether it came from this plan.
#
# A planned change meets an Org Graph change when its kind says the change
# moves its subject's facet ({TeamPlanning::Events::Change.subject_moved_by}).
# A person's placements are one facet, so a move in one of them meets the
# plan's whole list for that person.
#
# @example
#   TeamPlanning::Drift.new(context:, plan:).call.changes.reject(&:from_plan)
class TeamPlanning::Drift
  # @!attribute from [Date] the day before the base date
  # @!attribute to [Date] today
  # @!attribute changes [Array<Drifted>] in effective date order
  # @!attribute names [Hash{String => String}] person id => name for everyone the changes name
  Report = Data.define(:from, :to, :changes, :names) do
    # @param person_id [String]
    # @return [String]
    def name_of(person_id) = names.fetch(person_id, Person::FORMER_MEMBER)
  end

  # @!attribute change [OrgGraph::ChangesBetween::Change]
  # @!attribute from_plan [Boolean] whether it was applied from this plan
  # @!attribute meets [Array<Met>] the plan's changes to the facet it moves
  Drifted = Data.define(:change, :from_plan, :meets)

  # @!attribute scenario_id [String] the plan's id for the root
  # @!attribute change_id [String] the planned change's event id
  # @!attribute facet [String]
  # @!attribute subject_id [String]
  Met = Data.define(:scenario_id, :change_id, :facet, :subject_id)

  # @param context [AuthorizationContext]
  # @param plan [TeamPlanningPlan]
  # @param today [Date] the window's last day, as a UTC date
  # @param repository [TeamPlanning::Repository]
  def initialize(context:, plan:, today: Time.now.utc.to_date, repository: TeamPlanning::Repository.new)
    @context = context
    @plan = plan
    @today = today
    @repository = repository
  end

  # A plan whose base is still to come reads what the Org Graph knows now,
  # so it has no drift yet.
  #
  # @return [Report]
  # @raise [Pundit::NotAuthorizedError] when the caller can't open the plan or see the Org Graph
  def call
    Pundit.authorize(@context, @plan, :show?, policy_class: PlanPolicy)
    from = @plan.base_on - 1
    changes = @today > from ? OrgGraph::ChangesBetween.new(context: @context, from:, to: @today, by: :learned).call.changes : []

    planned = planned_changes
    from_plan = plan_ids(changes.map(&:event_id))
    drifted = changes.map { Drifted.new(change: it, from_plan: from_plan[it.event_id] == @plan.id, meets: meeting(planned, it)) }
    Report.new(from:, to: @today, changes: drifted, names: names_for(changes))
  end

  private

  def planned_changes
    plan = @repository.load_plan(@plan.id)
    [ @plan.id, *plan.scenarios.keys ].flat_map do |scenario_id|
      plan.changes_in(scenario_id).index_by(&:key).values.map { [ scenario_id, it ] }
    end
  end

  def meeting(planned, change)
    planned.filter_map do |scenario_id, planned_change|
      subject_id = planned_change.data[:subject_id]
      next unless planned_change.class.subject_moved_by(change) == subject_id

      Met.new(scenario_id:, change_id: planned_change.event_id, facet: planned_change.class.facet, subject_id:)
    end
  end

  def plan_ids(event_ids)
    return {} if event_ids.empty?

    Rails.configuration.event_store.read.events(event_ids.uniq).to_h { [ it.event_id, it.data[:plan_id] ] }
  end

  def names_for(changes)
    ids = changes.flat_map { [ it.person_id, it.before&.dig("manager_id"), it.after&.dig("manager_id") ] }.compact.uniq
    ::Person.where(tenant_id: @plan.tenant_id, id: ids).pluck(:id, :name).to_h
  end
end
