# frozen_string_literal: true

# What the taxonomy's write tools share beyond {UnitWrite}: the admin-only
# check, the levels as they stand, and the payload both return.
module Operations::OrgGraph::TaxonomyWrite
  def policy_check
    authorize :org_graph, :edit_taxonomy?
  end

  private

  # @return [Array<OrgTaxonomyLevel>] top first
  def current_levels = OrgTaxonomyLevel.top_first.to_a

  # @param levels [Array<OrgTaxonomyLevel>]
  # @return [Array<Hash>] what define_taxonomy takes, keeping each level's id and name
  def taxonomy_of(levels) = levels.map { |level| { level_id: level.id, name: level.name } }

  # @return [Array<Hash>] `{ level_id, name, provider }`, top first
  def levels_payload
    current_levels.map { |level| { level_id: level.id, name: level.name, provider: level.provider } }
  end
end
