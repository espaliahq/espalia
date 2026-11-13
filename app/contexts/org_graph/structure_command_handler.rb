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

  private

  def with_structure(plan, &block)
    @repository.with_structure(plan:, cause_id: @cause_id, &block)
  end
end
