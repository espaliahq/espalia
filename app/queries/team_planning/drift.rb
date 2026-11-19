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
  # @!attribute names [Hash{String => String}] person or unit id => name for everyone and every unit the changes name
  Report = Data.define(:from, :to, :changes, :names) do
    # @param person_id [String]
    # @return [String]
    def name_of(person_id) = names.fetch(person_id, Person::FORMER_MEMBER)
  end

  # @!attribute change [OrgGraph::ChangesBetween::Change]
  # @!attribute from_plan [Boolean] whether it was applied from this plan
  # @!attribute meets [Array<Met>] the plan's changes to the facet it moves
  # @!attribute sources [Array<String>] who supplies what it moves, from {TeamPlanning::SourceOfTruth}
  # @!attribute outside [Array<String>] the fields {TeamPlanning::DriftScope} cut as outside the plan
  # @!attribute group [Group, nil] the type changes a structure change folds into it
  Drifted = Data.define(:change, :from_plan, :meets, :sources, :outside, :group) do
    def initialize(group: nil, **) = super
  end

  # @!attribute cause_id [String] the structure change's cause, the same on every read
  # @!attribute unit_ids [Array<String>] the units it retyped that the plan covers
  Group = Data.define(:cause_id, :unit_ids)

  # @!attribute scenario_id [String] the plan's id for the root
  # @!attribute change_id [String] the planned change's event id
  # @!attribute facet [String]
  # @!attribute subject_id [String]
  Met = Data.define(:scenario_id, :change_id, :facet, :subject_id)

  # @param context [AuthorizationContext]
  # @param plan [TeamPlanningPlan]
  # @param today [Date] the window's last day, the tenant's today
  # @param repository [TeamPlanning::Repository]
  def initialize(context:, plan:, today: Tenant.today, repository: TeamPlanning::Repository.new)
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
    return Report.new(from:, to: @today, changes: [], names: {}) unless @today > from

    changes = OrgGraph::ChangesBetween.new(context: @context, from:, to: @today, by: :learned, opened_at: @plan.base_known_at).call.changes
    return Report.new(from:, to: @today, changes: [], names: {}) if changes.empty?

    aggregate = @repository.load_plan(@plan.id)
    cuts = within_scope(aggregate, changes)
    changes = cuts.map(&:change)
    return Report.new(from:, to: @today, changes: [], names: {}) if changes.empty?

    planned = planned_changes(aggregate)
    events = events_by_id(changes.map(&:event_id))
    sources = TeamPlanning::SourceOfTruth.new(tenant_id: @plan.tenant_id)
                                         .preload(unit_ids: changes.flat_map { [ it.unit_id, it.from_unit_id ] },
                                                  succession_ids: changes.map(&:succession_id))
    drifted = cuts.map do |cut|
      change = cut.change
      Drifted.new(change:, from_plan: events[change.event_id]&.data&.dig(:plan_id) == @plan.id, meets: meeting(planned, change),
                  sources: sources.of_drift(change), outside: cut.outside)
    end
    drifted = grouped(drifted, events)
    named = drifted.map(&:change)
    sources.preload(unit_ids: named.map(&:unit_id).compact)
    Report.new(from:, to: @today, changes: drifted, names: names_for(changes + named, sources))
  end

  private

  # A plan covering the whole organisation keeps every change.
  def within_scope(aggregate, changes)
    return changes.map { TeamPlanning::DriftScope::Cut.new(change: it, outside: []) } if @plan.scope_unit_ids.blank?

    baseline = TeamPlanning::Baseline.new(context: @context, plan: @plan)
    base = baseline.structure
    whole = baseline.map_on(@plan.base_on, known_on: baseline.known_on, known_at: baseline.known_at, history: true, scoped: false)
    parents = (whole.units + whole.retired_units).to_h { [ it.id, it.parent_id ] }
    maps = [ @plan.id, *aggregate.scenarios.keys ].map { TeamPlanning::Resolution.new(context: @context, plan: @plan, scenario_id: it, base:).structure(aggregate) }
    @scope = TeamPlanning::DriftScope.new(base, maps, parents:)
    @scope.call(changes, known: known_moves(baseline, changes), through: @today)
  end

  # What the baseline knew would change after its day, which the window,
  # reading only what was learned since, never holds.
  def known_moves(baseline, changes)
    to = [ @today, *changes.map(&:effective_on) ].max
    OrgGraph::ChangesBetween.new(context: @context, from: @plan.base_on, to:, known_on: baseline.known_on, known_at: baseline.known_at).call.changes
  end

  def planned_changes(plan)
    [ @plan.id, *plan.scenarios.keys ].flat_map do |scenario_id|
      plan.changes_in(scenario_id).index_by(&:key).values.map { [ scenario_id, it ] }
    end
  end

  def meeting(planned, change)
    planned.filter_map do |scenario_id, planned_change|
      subject_id = planned_change.data[:subject_id]
      next unless planned_change.class.moved_by?(planned_change, change)

      Met.new(scenario_id:, change_id: planned_change.event_id, facet: planned_change.key.last, subject_id:)
    end
  end

  def events_by_id(event_ids)
    return {} if event_ids.empty?

    Rails.configuration.event_store.read.events(event_ids.uniq).index_by(&:event_id)
  end

  # A structure declared or withdrawn retypes every unit beneath its unit
  # under one cause, so its type changes read as one item, in the place of
  # the first. Each stays a type change through the scope's cut, so only the
  # units the plan covers count, and a declaring unit it doesn't cover goes
  # unnamed.
  def grouped(drifted, events)
    cause_of = drifted.select { it.change.kind == :unit_kind_changed }
                      .to_h { [ it.change.event_id, events[it.change.event_id]&.metadata&.dig(:correlation_id) ] }.compact
    structures = OrgUnitActivity.where(cause_id: cause_of.values.uniq, subject: "structure").index_by(&:cause_id)
    return drifted if structures.empty?

    members = drifted.group_by { structures.key?(cause_of[it.change.event_id]) && cause_of[it.change.event_id] }
    drifted.filter_map do |item|
      cause_id = cause_of[item.change.event_id]
      next item unless structures.key?(cause_id)
      next unless members[cause_id].first.equal?(item)

      structure_item(structures[cause_id], members[cause_id])
    end
  end

  def structure_item(structure, members)
    changes = members.map(&:change)
    named = @scope.nil? || @scope.covers_unit?(structure.unit_id)
    providers = changes.map(&:provider).uniq
    change = OrgGraph::ChangesBetween::Change.new(
      kind: structure.after ? :structure_declared : :structure_withdrawn, effective_on: changes.first.effective_on,
      learned_at: changes.filter_map(&:learned_at).max, person_id: nil, unit_id: (structure.unit_id if named), from_unit_id: nil,
      succession_id: nil, fact: nil, before: nil, after: nil, provider: (providers.first if providers.one?),
      event_id: structure.cause_id, withdrawn: changes.all?(&:withdrawn)
    )
    Drifted.new(change:, from_plan: members.all?(&:from_plan), meets: members.flat_map(&:meets).uniq,
                sources: members.flat_map(&:sources).uniq, outside: named ? [] : [ "unit_id" ],
                group: Group.new(cause_id: structure.cause_id, unit_ids: members.map { it.change.unit_id }))
  end

  def names_for(changes, sources)
    ids = changes.flat_map { [ it.person_id, it.before&.dig("manager_id"), it.after&.dig("manager_id") ] }.compact.uniq
    units = changes.flat_map { [ it.unit_id, it.from_unit_id ] }.compact.uniq.select { @scope.nil? || @scope.covers_unit?(it) }
                   .filter_map { |id| (name = sources.unit_name(id)) && [ id, name ] }
    units.to_h.merge(::Person.where(tenant_id: @plan.tenant_id, id: ids).pluck(:id, :name).to_h)
  end
end
