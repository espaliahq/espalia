# frozen_string_literal: true

# What the taxonomy's write tools share beyond {UnitWrite}, which each
# includes first: the admin-only check, the levels as they stand, and the
# payload both return.
module Operations::OrgGraph::TaxonomyWrite
  # Overrides UnitWrite's tenant-wide check, so include this after it.
  #
  # @raise [Pundit::NotAuthorizedError] unless the caller is a tenant admin
  def policy_check
    authorize :org_graph, :edit_taxonomy?
  end

  private

  # @return [Array<OrgTaxonomyLevel>] top first
  def current_levels = OrgTaxonomyLevel.top_structure.to_a

  # @return [Array<Hash>] `{ level_id, name, provider, parent_ids, top }`, top first
  def levels_payload
    levels = current_levels
    rules = OrgTaxonomyLevel.rules_by_id(levels)
    levels.map do |level|
      { level_id: level.id, name: level.name, provider: level.provider, **rules[level.id] }
    end
  end
end
