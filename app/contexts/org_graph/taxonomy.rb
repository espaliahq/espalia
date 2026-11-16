# frozen_string_literal: true

# The kinds of unit a tenant's structure holds, and where each may sit: the
# kinds its parent may be, and whether it may sit at the top.
#
# A TaxonomyDefined level states its rules in `parent_level_ids` and `top`.
# A level written before those fields existed keeps the rule it was enforced
# under: it may sit under any level above it, or at the top. A level an HRIS
# provides is narrower, as the mirror has only ever read a unit's parent from
# the level directly above: that level when an HRIS provides it too, and
# otherwise none. The aggregate, the projections and the history all read
# rules through this class, so an old event means the same thing everywhere.
#
# @example
#   taxonomy = OrgGraph::Taxonomy.new(event.data[:levels], providers: { team_id => "hibob" })
#   taxonomy.allows?(squad_id, beneath: team_id)
class OrgGraph::Taxonomy
  ESPALIA = "espalia"

  # One kind of unit, with the kinds its parent may be.
  Kind = Data.define(:id, :name, :provider, :parent_ids, :top) do
    # @return [Boolean] whether a unit of this kind may sit at the top
    def top? = top
  end

  # @return [Array<Kind>] top first, in the order the taxonomy lists them
  attr_reader :kinds

  # @param levels [Array<Hash>] a TaxonomyDefined event's levels, top first
  # @param providers [Hash{String => String}] level_id => provider; Espalia when absent
  def initialize(levels, providers: {})
    levels = Array(levels).map { |level| level.to_h.symbolize_keys }
    @kinds = levels.each_with_index.map do |level, index|
      above = levels.first(index).map { |other| other[:level_id] }
      provider = providers.fetch(level[:level_id], ESPALIA)
      Kind.new(id: level[:level_id], name: level[:name], provider:,
               parent_ids: parent_ids(level, above, provider, providers), top: level.fetch(:top, true))
    end
    @by_id = @kinds.index_by(&:id)
  end

  # @param id [String]
  # @return [Kind, nil]
  def kind(id) = @by_id[id]

  # Whether a unit of one kind may sit beneath a unit of another.
  #
  # @param kind_id [String] the unit's kind
  # @param beneath [String] the parent's kind
  # @return [Boolean]
  def allows?(kind_id, beneath:) = kind(kind_id)&.parent_ids&.include?(beneath) || false

  # @param kind_id [String]
  # @return [Boolean]
  def may_be_top?(kind_id) = kind(kind_id)&.top? || false

  private

  def parent_ids(level, above, provider, providers)
    return Array(level[:parent_level_ids]) if level.key?(:parent_level_ids)
    return above if provider == ESPALIA

    directly_above = above.last
    directly_above && providers.fetch(directly_above, ESPALIA) != ESPALIA ? [ directly_above ] : []
  end
end
