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
  def current_levels = OrgTaxonomyLevel.top_first.to_a

  # @return [Array<Hash>] `{ level_id, name, provider }`, top first
  def levels_payload
    current_levels.map { |level| { level_id: level.id, name: level.name, provider: level.provider } }
  end

  # The commands refuse a taxonomy they can't keep with a message the caller
  # can act on, so it reaches them as a bad parameter.
  def refusing_as_parameter_errors
    yield
  rescue ArgumentError, RuntimeError => e
    raise Operations::Base::ParameterError, e.message
  end
end
