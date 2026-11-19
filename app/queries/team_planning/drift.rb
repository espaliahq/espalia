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
  # @!attribute group [Group, nil] the type changes a structure change, or a move between structures, folds into it
  Drifted = Data.define(:change, :from_plan, :meets, :sources, :outside, :group) do
    def initialize(group: nil, **) = super
  end

  # @!attribute cause_id [String] the cause the write and its type changes share
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
    sources.preload(unit_ids: named.flat_map { [ it.unit_id, *structures_of(it) ] }.compact)
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

  # A structure declared or withdrawn retypes every unit beneath its unit,
  # and a move between structures retypes the units it carries. Each writes
  # its type changes straight after itself, under one cause, so each type
  # change reads as part of the write it follows, as one item in the place of
  # the first. The event store says which write that is, and no projection
  # rebuild empties it. Each type change stays one through the scope's cut,
  # so only the units the plan covers count, and a structure whose declaring
  # unit the plan doesn't cover goes unnamed. A unit that moved out of the
  # plan reads as leaving it, as any move out does.
  def grouped(drifted, events)
    retyped = drifted.select { it.change.kind == :unit_kind_changed }.filter_map { events[it.change.event_id] }
    head_of = heads_of(retyped).transform_values { events[it.event_id] || it }
    drifted.each do |item|
      next unless (event = events[item.change.event_id]) && head?(event) && !left?(item.change)

      head_of[event.event_id] = event
    end
    return drifted if head_of.empty?

    members = drifted.select { head_of.key?(it.change.event_id) }.group_by { head_of[it.change.event_id].event_id }
    drifted.filter_map do |item|
      head = head_of[item.change.event_id]
      next item unless head
      next unless members[head.event_id].first.equal?(item)

      head.is_a?(OrgGraph::Events::UnitMoved) ? move_item(head, members[head.event_id]) : structure_item(head, members[head.event_id])
    end
  end

  # Each type change's id => the write it follows. A walk out from a type
  # change reads the run of its cause's events around it. Another request can
  # write between two writes of one cause, so each run is walked.
  def heads_of(retyped)
    stream = EventStreamNaming.org_structure_stream
    walked = Set.new
    retyped.each_with_object({}) do |event, head_of|
      next if walked.include?(event.event_id) || (cause_id = cause(event)).nil?

      same_cause = ->(other) { cause(other) == cause_id }
      before = store.read.stream(stream).backward.from(event.event_id).each.take_while(&same_cause).reverse
      after = store.read.stream(stream).from(event.event_id).each.take_while(&same_cause)
      head = nil
      [ *before, event, *after ].each do |written|
        walked << written.event_id
        if head?(written) then head = written
        elsif written.is_a?(OrgGraph::Events::UnitKindChanged) then head_of[written.event_id] = head if head && carries?(head, written)
        else head = nil
        end
      end
    end
  end

  def head?(event)
    case event
    when OrgGraph::Events::TaxonomyDefined then event.data[:structure_unit_id].present?
    when OrgGraph::Events::UnitMoved then event.data.key?(:conversion)
    else false
    end
  end

  # A write's conversion takes each type it changes to the new one, so a
  # type change written after it in the same request, but apart from it,
  # stays its own. A change back restores each unit's own type, which no one
  # conversion can say when two types became one, so it holds every type
  # change back that follows it.
  def carries?(head, retyped)
    return true if head.data[:changed_back_id] && retyped.data[:changed_back_id]

    head.data[:conversion].to_h.transform_keys(&:to_s)[retyped.data[:previous_level_id].to_s] == retyped.data[:level_id]
  end

  def cause(event) = event.metadata[:correlation_id]

  def store = Rails.configuration.event_store

  def covered?(unit_id) = @scope.nil? || @scope.covers_unit?(unit_id)

  def left?(change) = change.unit_id.present? && !covered?(change.unit_id)

  def structure_item(head, members)
    unit_id = head.data[:structure_unit_id]
    named = covered?(unit_id)
    folded(members, kind: head.data[:levels].present? ? :structure_declared : :structure_withdrawn, head:,
                    unit_id: (unit_id if named), outside: named ? [] : [ "unit_id" ])
  end

  # The mover keeps the scope's cut of its own move, which judged it when it
  # moved, and so does a move from before the base, which has no before. A
  # move written before it named the structures it crossed says only that it
  # crossed, with neither side.
  def move_item(head, members)
    data = head.data
    own = members.find { it.change.event_id == head.event_id }&.change
    named = own&.unit_id.present?
    sides = data.key?(:structure_joined_id) ? { "before" => data[:structure_left_id], "after" => data[:structure_joined_id] } : {}
    sides.delete("before") if own && own.before.nil?
    hidden = sides.select { |_side, unit_id| unit_id && !covered?(unit_id) }.keys
    structure = sides.to_h { |side, unit_id| [ side, { "structure_unit_id" => (unit_id unless hidden.include?(side)) } ] }
    backdated = "before" if own && own.before.nil?
    folded(members, kind: :moved_between_structures, head:, unit_id: (data[:unit_id] if named),
                    before: structure["before"], after: structure["after"], outside: [ ("unit_id" unless named), *hidden, backdated ].compact)
  end

  def folded(members, kind:, head:, unit_id:, outside:, before: nil, after: nil)
    changes = members.map(&:change)
    retyped = members.select { it.change.kind == :unit_kind_changed }
    providers = changes.map(&:provider).uniq
    change = OrgGraph::ChangesBetween::Change.new(
      kind:, effective_on: changes.first.effective_on, learned_at: changes.filter_map(&:learned_at).max, person_id: nil, unit_id:,
      from_unit_id: nil, succession_id: nil, fact: nil, before:, after:, provider: (providers.first if providers.one?),
      event_id: head.event_id, withdrawn: changes.all?(&:withdrawn)
    )
    Drifted.new(change:, from_plan: members.all?(&:from_plan), meets: members.flat_map(&:meets).uniq,
                sources: members.flat_map(&:sources).uniq, outside:,
                group: Group.new(cause_id: cause(head), unit_ids: retyped.map { it.change.unit_id }))
  end

  def names_for(changes, sources)
    ids = changes.flat_map { [ it.person_id, it.before&.dig("manager_id"), it.after&.dig("manager_id") ] }.compact.uniq
    units = changes.flat_map { [ it.unit_id, it.from_unit_id, *structures_of(it) ] }.compact.uniq.select { covered?(it) }
                   .filter_map { |id| (name = sources.unit_name(id)) && [ id, name ] }
    units.to_h.merge(::Person.where(tenant_id: @plan.tenant_id, id: ids).pluck(:id, :name).to_h)
  end

  def structures_of(change) = change.kind == :moved_between_structures ? [ change.before, change.after ].compact.pluck("structure_unit_id") : []
end
