# frozen_string_literal: true

# What the taxonomy's write tools share beyond {UnitWrite}, which each
# includes first: who may change the structure they write, the unit types as
# they stand, and the payload each returns.
#
# A write names its structure: the top one by default, or a unit's own
# ([#494](https://github.com/espaliahq/espalia/issues/494)) when
# {#structure_unit} returns that unit.
module Operations::OrgGraph::TaxonomyWrite
  # Overrides UnitWrite's tenant-wide check, so include this after it. It
  # refuses before the write reads the structure's types, with the command's
  # own sentence.
  #
  # @raise [OrgGraph::Authorization::Refused] unless the caller may change the structure,
  #   with the command's own sentence, which names no type
  def policy_check
    authorize :org_graph, :show?
    return if Pundit.policy!(context, :org_graph).edit_structure_of?(structure_unit)

    raise OrgGraph::Authorization::Refused, OrgGraph::Authorization.structure_refusal(structure_unit)
  end

  private

  # @return [OrgUnit, nil] the unit whose own structure this writes, nil for the top structure
  def structure_unit
    return @structure_unit if defined?(@structure_unit)

    @structure_unit = params[:structure_unit_id] && live_unit!(:structure_unit_id)
  end

  # @return [Array<OrgTaxonomyLevel>] top first
  def current_levels = OrgTaxonomyLevel.in_structure(structure_unit&.id).to_a

  # @return [Array<Hash>] `{ level_id, name, provider, parent_ids, top }`, top first
  def levels_payload
    levels = current_levels
    rules = OrgTaxonomyLevel.rules_by_id(levels)
    levels.map do |level|
      { level_id: level.id, name: level.name, provider: level.provider, **rules[level.id] }
    end
  end

  # @return [Hash] `{ structure_unit_id: }` for a unit's own structure, else empty
  def in_structure = structure_unit ? { structure_unit_id: structure_unit.id } : {}
end
