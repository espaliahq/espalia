# frozen_string_literal: true

# Handles commands for a tenant's Org Graph structure: its taxonomy, its
# units, and who provides each level and each kind of person fact.
#
# Loads {OrgGraph::StructureAggregate} through {OrgGraph::Repository}, which
# adds the tenant to every event's metadata. Arguments pass straight through
# to the aggregate, which documents them.
#
class OrgGraph::StructureCommandHandler
  # @param repository [OrgGraph::Repository]
  def initialize(repository: OrgGraph::Repository.new)
    @repository = repository
  end

  # @see OrgGraph::StructureAggregate#define_taxonomy
  def define_taxonomy(levels, **options)
    @repository.with_structure { |structure| structure.define_taxonomy(levels, **options) }
  end

  # @see OrgGraph::StructureAggregate#set_level_provider
  def set_level_provider(level_id, provider, **options)
    @repository.with_structure { |structure| structure.set_level_provider(level_id, provider, **options) }
  end

  # @see OrgGraph::StructureAggregate#set_fact_provider
  def set_fact_provider(fact, provider, **options)
    @repository.with_structure { |structure| structure.set_fact_provider(fact, provider, **options) }
  end

  # @see OrgGraph::StructureAggregate#create_unit
  def create_unit(unit_id, name, **options)
    @repository.with_structure { |structure| structure.create_unit(unit_id, name, **options) }
  end

  # @see OrgGraph::StructureAggregate#rename_unit
  def rename_unit(unit_id, name, **options)
    @repository.with_structure { |structure| structure.rename_unit(unit_id, name, **options) }
  end

  # @see OrgGraph::StructureAggregate#move_unit
  def move_unit(unit_id, parent_id, **options)
    @repository.with_structure { |structure| structure.move_unit(unit_id, parent_id, **options) }
  end

  # @see OrgGraph::StructureAggregate#retire_unit
  def retire_unit(unit_id, **options)
    @repository.with_structure { |structure| structure.retire_unit(unit_id, **options) }
  end
end
