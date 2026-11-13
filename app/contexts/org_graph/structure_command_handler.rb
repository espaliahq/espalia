# frozen_string_literal: true

# Handles commands for a tenant's Org Graph structure: its taxonomy, its
# units, and who provides each level and each kind of person fact.
#
# Loads {OrgGraph::StructureAggregate} through {OrgGraph::Repository}, which
# adds the tenant to every event's metadata. Arguments pass straight through
# to the aggregate, which documents them.
#
# A handler built with an actor also refuses what {OrgGraphPolicy} doesn't
# let that actor change. See {OrgGraph::Authorization}.
#
class OrgGraph::StructureCommandHandler
  include OrgGraph::Authorization

  # @param repository [OrgGraph::Repository]
  # @param actor [AuthorizationContext, nil] who is acting, checked against
  #   {OrgGraphPolicy}; nil for the system, which is not checked
  def initialize(repository: OrgGraph::Repository.new, actor: nil)
    @repository = repository
    @actor = actor
  end

  # @see OrgGraph::StructureAggregate#define_taxonomy
  def define_taxonomy(levels, **options)
    authorize_structure!
    @repository.with_structure { |structure| structure.define_taxonomy(levels, **attributed(options, :defined_by_id)) }
  end

  # @see OrgGraph::StructureAggregate#set_level_provider
  def set_level_provider(level_id, provider, **options)
    authorize_structure!
    @repository.with_structure { |structure| structure.set_level_provider(level_id, provider, **attributed(options, :set_by_id)) }
  end

  # @see OrgGraph::StructureAggregate#set_fact_provider
  def set_fact_provider(fact, provider, **options)
    authorize_structure!
    @repository.with_structure { |structure| structure.set_fact_provider(fact, provider, **attributed(options, :set_by_id)) }
  end

  # @see OrgGraph::StructureAggregate#claim_facts
  def claim_facts(facts, provider, **options)
    authorize_structure!
    claimed = []
    @repository.with_structure { |structure| claimed = structure.claim_facts(facts, provider, **attributed(options, :set_by_id)) }
    claimed
  end

  # @see OrgGraph::StructureAggregate#add_unit_owner
  def add_unit_owner(unit_id, person_id, **options)
    authorize_unit!(unit_id)
    @repository.with_structure { |structure| structure.add_unit_owner(unit_id, person_id, **attributed(options, :added_by_id)) }
  end

  # @see OrgGraph::StructureAggregate#remove_unit_owner
  def remove_unit_owner(unit_id, person_id, **options)
    authorize_unit!(unit_id)
    @repository.with_structure { |structure| structure.remove_unit_owner(unit_id, person_id, **attributed(options, :removed_by_id)) }
  end

  # @see OrgGraph::StructureAggregate#create_unit
  def create_unit(unit_id, name, **options)
    authorize_new_unit!(options[:parent_id])
    @repository.with_structure { |structure| structure.create_unit(unit_id, name, **attributed(options, :created_by_id)) }
  end

  # @see OrgGraph::StructureAggregate#rename_unit
  def rename_unit(unit_id, name, **options)
    authorize_unit!(unit_id)
    @repository.with_structure { |structure| structure.rename_unit(unit_id, name, **attributed(options, :renamed_by_id)) }
  end

  # @see OrgGraph::StructureAggregate#move_unit
  def move_unit(unit_id, parent_id, **options)
    authorize_move_unit!(unit_id, parent_id)
    @repository.with_structure { |structure| structure.move_unit(unit_id, parent_id, **attributed(options, :moved_by_id)) }
  end

  # Runs in one transaction with {OrgGraph::SyncHandlers::RetiredUnitMemberships},
  # since RES commits the retirement before its subscribers run.
  #
  # @see OrgGraph::StructureAggregate#retire_unit
  def retire_unit(unit_id, **options)
    ActiveRecord::Base.transaction do
      authorize_unit!(unit_id)
      @repository.with_structure { |structure| structure.retire_unit(unit_id, **attributed(options, :retired_by_id)) }
    end
  end

  # One transaction, as {#retire_unit}, when it retires the predecessors.
  #
  # @see OrgGraph::StructureAggregate#record_succession
  def record_succession(succession_id, **options)
    ActiveRecord::Base.transaction do
      authorize_succession!([ options[:predecessor_ids], options[:successor_ids] ])
      @repository.with_structure { |structure| structure.record_succession(succession_id, **attributed(options, :stated_by_id)) }
    end
  end
end
