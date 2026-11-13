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

  # @see OrgGraph::StructureAggregate#define_taxonomy
  def define_taxonomy(levels, **options)
    plan, options = OrgGraph::PlanReference.extract(options)
    authorize_structure!
    with_structure(plan) { |structure| structure.define_taxonomy(levels, **attributed(options, :defined_by_id)) }
  end

  # @see OrgGraph::StructureAggregate#set_level_provider
  def set_level_provider(level_id, provider, **options)
    plan, options = OrgGraph::PlanReference.extract(options)
    authorize_structure!
    with_structure(plan) { |structure| structure.set_level_provider(level_id, provider, **attributed(options, :set_by_id)) }
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

  # @see OrgGraph::StructureAggregate#move_unit
  def move_unit(unit_id, parent_id, **options)
    plan, options = OrgGraph::PlanReference.extract(options)
    authorize_move_unit!(unit_id, parent_id)
    with_structure(plan) { |structure| structure.move_unit(unit_id, parent_id, **attributed(options, :moved_by_id)) }
  end

  # Runs in one transaction with {OrgGraph::SyncHandlers::RetiredUnitMemberships},
  # since RES commits the retirement before its subscribers run.
  #
  # @see OrgGraph::StructureAggregate#retire_unit
  def retire_unit(unit_id, **options)
    plan, options = OrgGraph::PlanReference.extract(options)
    ActiveRecord::Base.transaction do
      authorize_unit!(unit_id)
      with_structure(plan) { |structure| structure.retire_unit(unit_id, **attributed(options, :retired_by_id)) }
    end
  end

  # One transaction, as {#retire_unit}, when it retires the predecessors.
  #
  # @see OrgGraph::StructureAggregate#record_succession
  def record_succession(succession_id, **options)
    plan, options = OrgGraph::PlanReference.extract(options)
    ActiveRecord::Base.transaction do
      authorize_succession!([ options[:predecessor_ids], options[:successor_ids] ])
      with_structure(plan) { |structure| structure.record_succession(succession_id, **attributed(options, :stated_by_id)) }
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
  def apply_succession(succession_id, predecessor_ids:, successor_ids:, effective_on:, placements: {}, **options)
    plan, options = OrgGraph::PlanReference.extract(options)
    options = attributed(options, :stated_by_id)
    ActiveRecord::Base.transaction do
      authorize_succession!([ predecessor_ids, successor_ids ])
      moves = placement_moves(placements, Array(predecessor_ids), Array(successor_ids))
      place(moves, effective_on, plan, moved_by_id: options[:stated_by_id])
      with_structure(plan) do |structure|
        structure.record_succession(succession_id, predecessor_ids:, successor_ids:, effective_on:,
                                                   **options, retire_predecessors: true)
      end
    end
  end

  private

  # Checks every placement before any is written. Someone already in their
  # successor and in no predecessor was placed when the plan was last applied.
  def placement_moves(placements, predecessor_ids, successor_ids)
    predecessor_ids, successor_ids = [ predecessor_ids, successor_ids ].map { |ids| ids.map { |id| id.to_s.downcase } }
    held = OrgMembership.where(person_id: placements.keys, unit_id: predecessor_ids + successor_ids)
                        .group_by(&:person_id)

    placements.filter_map do |person_id, successor_id|
      successor_id = successor_id.to_s.downcase
      raise ArgumentError, "A placement must name one of the successors" unless successor_ids.include?(successor_id)

      memberships = held.fetch(person_id.to_s.downcase, [])
      from = memberships.select { |membership| predecessor_ids.include?(membership.unit_id) }
      next if from.empty? && memberships.any? { |membership| membership.unit_id == successor_id }
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
end
