# frozen_string_literal: true

# Handles commands for a tenant's Org Graph structure: its taxonomy, its
# units, and who provides each level and each kind of person fact.
#
# Loads {OrgGraph::StructureAggregate} through {OrgGraph::Repository}, which
# adds the tenant to every event's metadata. Arguments pass straight through
# to the aggregate, which documents them.
#
# Each handler names its actor and refuses what {OrgGraphPolicy} doesn't let
# that actor change. See {OrgGraph::Authorization}.
#
# Every command also takes `plan_id:` and `plan_change_id:`, the plan change
# it was applied from, and writes them on each event. See {OrgGraph::PlanReference}.
#
class OrgGraph::StructureCommandHandler
  include OrgGraph::Authorization

  # @param actor [AuthorizationContext, Object] who is acting, checked against
  #   {OrgGraphPolicy}, or {OrgGraph::Authorization::SYSTEM}, which is not
  # @param cause_id [String, nil] shared by every event this handler writes,
  #   as their correlation id: a plan's approval, say. Without one, events
  #   keep the request's.
  # @param repository [OrgGraph::Repository]
  # @raise [ArgumentError] without an actor
  def initialize(actor:, cause_id: nil, repository: OrgGraph::Repository.new)
    @actor = actor!(actor)
    @cause_id = cause_id
    @repository = repository
  end

  # The history and the structure record each kind, so every change to the
  # kinds waits for their rebuilds, as a provider change does.
  #
  # @see OrgGraph::StructureAggregate#define_taxonomy
  # @raise [ProjectionVersion::Rebuilding] while the history or the structure is rebuilt
  def define_taxonomy(levels, **options)
    plan, options = OrgGraph::PlanReference.extract(options)
    authorize_taxonomy!
    unless_kinds_rebuilding do
      with_structure(plan) { |structure| structure.define_taxonomy(levels, **attributed(options, :defined_by_id)) }
    end
  end

  # @see OrgGraph::StructureAggregate#declare_structure
  # @raise [ProjectionVersion::Rebuilding] while the history or the structure is rebuilt
  def declare_structure(unit_id, **options)
    authorize_structure_of!(unit_id)
    unless_kinds_rebuilding do
      with_structure(OrgGraph::PlanReference.new) { |structure| structure.declare_structure(unit_id, **attributed(options, :defined_by_id)) }
    end
  end

  # @see OrgGraph::StructureAggregate#withdraw_structure
  # @raise [ProjectionVersion::Rebuilding] while the history or the structure is rebuilt
  def withdraw_structure(unit_id, **options)
    authorize_structure_of!(unit_id)
    unless_kinds_rebuilding do
      with_structure(OrgGraph::PlanReference.new) { |structure| structure.withdraw_structure(unit_id, **attributed(options, :withdrawn_by_id)) }
    end
  end

  # @see OrgGraph::StructureAggregate#add_level
  # @raise [ProjectionVersion::Rebuilding] while the history or the structure is rebuilt
  def add_level(level_id, name, **options)
    authorize_structure_of!(options[:structure_unit_id])
    unless_kinds_rebuilding do
      with_structure(OrgGraph::PlanReference.new) { |structure| structure.add_level(level_id, name, **attributed(options, :defined_by_id)) }
    end
  end

  # @see OrgGraph::StructureAggregate#set_kind_parents
  # @raise [ProjectionVersion::Rebuilding] while the history or the structure is rebuilt
  def set_kind_parents(level_id, **options)
    authorize_structure_of!(options[:structure_unit_id])
    unless_kinds_rebuilding do
      with_structure(OrgGraph::PlanReference.new) { |structure| structure.set_kind_parents(level_id, **attributed(options, :defined_by_id)) }
    end
  end

  # @see OrgGraph::StructureAggregate#remove_level
  # @raise [ProjectionVersion::Rebuilding] while the history or the structure is rebuilt
  def remove_level(level_id, **options)
    plan, options = OrgGraph::PlanReference.extract(options)
    authorize_structure_of!(options[:structure_unit_id])
    unless_kinds_rebuilding do
      with_structure(plan) { |structure| structure.remove_level(level_id, **attributed(options, :defined_by_id)) }
    end
  end

  # @see OrgGraph::StructureAggregate#set_level_provider
  # @raise [ProjectionVersion::Rebuilding] while the history or the structure is rebuilt
  def set_level_provider(level_id, provider, **options)
    plan, options = OrgGraph::PlanReference.extract(options)
    authorize_structure!
    unless_kinds_rebuilding do
      with_structure(plan) { |structure| structure.set_level_provider(level_id, provider, **attributed(options, :set_by_id)) }
    end
  end

  # @see OrgGraph::StructureAggregate#hand_over_level
  # @raise [ProjectionVersion::Rebuilding] while the history or the structure is rebuilt
  def hand_over_level(level_id, provider, **options)
    authorize_structure!
    unless_kinds_rebuilding do
      with_structure(OrgGraph::PlanReference.new) { |structure| structure.hand_over_level(level_id, provider, **attributed(options, :set_by_id)) }
    end
  end

  # @see OrgGraph::StructureAggregate#hand_back_level
  # @raise [ProjectionVersion::Rebuilding] while the history or the structure is rebuilt
  def hand_back_level(level_id, **options)
    authorize_structure!
    unless_kinds_rebuilding do
      with_structure(OrgGraph::PlanReference.new) { |structure| structure.hand_back_level(level_id, **attributed(options, :set_by_id)) }
    end
  end

  # @see OrgGraph::StructureAggregate#set_fact_provider
  def set_fact_provider(fact, provider, **options)
    plan, options = OrgGraph::PlanReference.extract(options)
    authorize_structure!
    with_structure(plan) { |structure| structure.set_fact_provider(fact, provider, **attributed(options, :set_by_id)) }
  end

  # @see OrgGraph::StructureAggregate#claim_facts
  def claim_facts(facts, provider, **options)
    plan, options = OrgGraph::PlanReference.extract(options)
    authorize_structure!
    claimed = []
    with_structure(plan) { |structure| claimed = structure.claim_facts(facts, provider, **attributed(options, :set_by_id)) }
    claimed
  end

  # @see OrgGraph::StructureAggregate#add_unit_owner
  def add_unit_owner(unit_id, person_id, **options)
    plan, options = OrgGraph::PlanReference.extract(options)
    authorize_unit!(unit_id)
    with_structure(plan) { |structure| structure.add_unit_owner(unit_id, person_id, **attributed(options, :added_by_id)) }
  end

  # @see OrgGraph::StructureAggregate#remove_unit_owner
  def remove_unit_owner(unit_id, person_id, **options)
    plan, options = OrgGraph::PlanReference.extract(options)
    authorize_unit!(unit_id)
    with_structure(plan) { |structure| structure.remove_unit_owner(unit_id, person_id, **attributed(options, :removed_by_id)) }
  end

  # @see OrgGraph::StructureAggregate#create_unit
  def create_unit(unit_id, name, **options)
    plan, options = OrgGraph::PlanReference.extract(options)
    authorize_new_unit!(options[:parent_id])
    with_structure(plan) { |structure| structure.create_unit(unit_id, name, **attributed(options, :created_by_id)) }
  end

  # @see OrgGraph::StructureAggregate#rename_unit
  def rename_unit(unit_id, name, **options)
    plan, options = OrgGraph::PlanReference.extract(options)
    authorize_unit!(unit_id)
    with_structure(plan) { |structure| structure.rename_unit(unit_id, name, **attributed(options, :renamed_by_id)) }
  end

  # A move with a conversion also needs the right to change the structure it
  # moves into, checked under the structure's lock before anything about the
  # move is. Its type changes share the move's cause even outside a request,
  # so change back sees them as one change.
  #
  # @see OrgGraph::StructureAggregate#move_unit
  def move_unit(unit_id, parent_id, **options)
    plan, options = OrgGraph::PlanReference.extract(options)
    authorize_move_unit!(unit_id, parent_id)
    cause_id = @cause_id || (shared_cause unless options[:conversion].nil?)
    @repository.with_structure(plan:, cause_id:) do |structure|
      authorize_move_into!(structure.structure_joined_beneath(parent_id)) unless options[:conversion].nil?
      structure.move_unit(unit_id, parent_id, **attributed(options, :moved_by_id))
    end
  end

  # @see OrgGraph::StructureAggregate#change_unit_kind
  def change_unit_kind(unit_id, level_id, **options)
    plan, options = OrgGraph::PlanReference.extract(options)
    authorize_unit_kind!
    with_structure(plan) { |structure| structure.change_unit_kind(unit_id, level_id, **attributed(options, :kind_changed_by_id)) }
  end

  # Runs in one transaction with {OrgGraph::SyncHandlers::RetiredUnitMemberships},
  # since RES commits the retirement before its subscribers run.
  #
  # @see OrgGraph::StructureAggregate#retire_unit
  def retire_unit(unit_id, **options)
    plan, options = OrgGraph::PlanReference.extract(options)
    ActiveRecord::Base.transaction do
      authorize_unit!(unit_id)
      with_structure(plan) do |structure|
        unless_kinds_rebuilding_for(structure, [ unit_id ]) { structure.retire_unit(unit_id, **attributed(options, :retired_by_id)) }
      end
    end
  end

  # One transaction, as {#retire_unit}, when it retires the predecessors.
  #
  # @see OrgGraph::StructureAggregate#record_succession
  def record_succession(succession_id, **options)
    plan, options = OrgGraph::PlanReference.extract(options)
    ActiveRecord::Base.transaction do
      authorize_succession!([ options[:predecessor_ids], options[:successor_ids] ])
      with_structure(plan) do |structure|
        retiring = options[:retire_predecessors] ? Array(options[:predecessor_ids]) : []
        unless_kinds_rebuilding_for(structure, retiring) { structure.record_succession(succession_id, **attributed(options, :stated_by_id)) }
      end
    end
  end

  # Applies a split, a merge or a replacement, as approving a plan does: moves
  # each person `placements` names to their successor, records the succession
  # and retires the predecessors, all in one transaction. A merge or a
  # replacement then moves every other member to its one successor; a split
  # ends their membership, as {OrgGraph::SyncHandlers::RetiredUnitMemberships}
  # does. Build the handler with the approval as its `cause_id:`, so every
  # event shares it.
  #
  # @param succession_id [String]
  # @param predecessor_ids [Array<String>]
  # @param successor_ids [Array<String>]
  # @param effective_on [Date, String]
  # @param placements [Hash{String => String}] person id => the successor
  #   they move to
  # @param options [Hash] other keywords accepted by
  #   {OrgGraph::StructureAggregate#record_succession}
  # @raise [ArgumentError] if a placement names a unit outside the successors,
  #   or a person who isn't a member of exactly one predecessor
  # @raise [ProjectionVersion::Rebuilding] while the member list is rebuilt,
  #   or the kinds are when a predecessor declares a structure
  def apply_succession(succession_id, predecessor_ids:, successor_ids:, effective_on:, placements: {}, **options)
    plan, options = OrgGraph::PlanReference.extract(options)
    options = attributed(options, :stated_by_id)
    ProjectionVersion.unless_rebuilding(OrgGraph::Projections::Members::PROJECTION_NAME) do # placement_moves reads it
      ActiveRecord::Base.transaction do
        @repository.lock_structure # before any person's, the order retire_unit takes them in
        authorize_succession!([ predecessor_ids, successor_ids ])
        applied = OrgUnitSuccession.exists?(succession_id: succession_id.to_s.downcase)
        moves = placement_moves(placements, Array(predecessor_ids), Array(successor_ids), applied:)
        place(moves, effective_on, plan, moved_by_id: options[:stated_by_id])
        with_structure(plan) do |structure|
          unless_kinds_rebuilding_for(structure, Array(predecessor_ids)) do
            structure.record_succession(succession_id, predecessor_ids:, successor_ids:, effective_on:,
                                                       **options, retire_predecessors: true)
          end
        end
      end
    end
  end

  private

  # The history records a provider change only when it changes the kind, so a
  # change that reached both the live subscriber and a replay would leave the
  # replay's older provider standing. The structure holds each kind's rules,
  # and places units by them, so a change mid-rebuild could be overtaken too.
  def unless_kinds_rebuilding(&)
    ProjectionVersion.unless_rebuilding(OrgGraph::Projections::History::PROJECTION_NAME,
                                        OrgGraph::Projections::Structure::PROJECTION_NAME, &)
  end

  # Only a retirement that withdraws a structure changes the kinds. Guarding
  # every retirement would refuse the HRIS mirror's during a History rebuild,
  # which records each refusal as a sync error. The aggregate decides, since a
  # Structure rebuild empties the read model.
  def unless_kinds_rebuilding_for(structure, retiring_ids, &)
    declared = structure.declared_structures
    retiring_ids.any? { declared.key?(it.to_s.downcase) } ? unless_kinds_rebuilding(&) : yield
  end

  # Checks every placement before any is written. Once the succession is
  # recorded, someone already in their successor and in no predecessor was
  # placed when the plan was last applied.
  def placement_moves(placements, predecessor_ids, successor_ids, applied:)
    predecessor_ids, successor_ids = [ predecessor_ids, successor_ids ].map { |ids| ids.map { |id| id.to_s.downcase } }
    held = OrgMembership.where(person_id: placements.keys, unit_id: predecessor_ids + successor_ids)
                        .group_by(&:person_id)

    placements.filter_map do |person_id, successor_id|
      successor_id = successor_id.to_s.downcase
      raise ArgumentError, "A placement must name one of the successors" unless successor_ids.include?(successor_id)

      memberships = held.fetch(person_id.to_s.downcase, [])
      from = memberships.select { |membership| predecessor_ids.include?(membership.unit_id) }
      next if applied && from.empty? && memberships.any? { |membership| membership.unit_id == successor_id }
      raise ArgumentError, "Only a member of one predecessor can be placed" unless from.one?

      [ from.first, successor_id ]
    end
  end

  # As the system, since the succession's check already covers each move:
  # whoever may change every unit in it may move a member between them.
  def place(moves, effective_on, plan, moved_by_id:)
    people = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM, cause_id: @cause_id, repository: @repository)
    moves.each do |membership, successor_id|
      on = OrgGraph::SyncHandlers::RetiredUnitMemberships.leaving_on(membership, on: effective_on, repository: @repository)
      people.move_membership(membership.person_id, membership.unit_id, successor_id,
                             effective_on: on, moved_by_id: moved_by_id, **plan.to_h)
    end
  end

  def with_structure(plan, &block)
    @repository.with_structure(plan:, cause_id: @cause_id, &block)
  end

  def shared_cause = Rails.configuration.event_store.metadata[:correlation_id] || SecureRandom.uuid_v7
end
