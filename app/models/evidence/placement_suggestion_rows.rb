# frozen_string_literal: true

# What the hub needs to show the pending placement suggestions under a set of
# items: the rows, and each one's capability name, level code and expectation
# (resolved once, through {Evidence::CellContextResolver}).
class Evidence::PlacementSuggestionRows
  NONE = { suggestions: [], cells: {} }.freeze

  # @param items [Array<EvidenceItem>]
  # @return [Hash{String => Hash}] item id => { suggestions:, cells: }, only
  #   for items with pending suggestions
  def self.for(items)
    by_item = EvidencePlacementSuggestion.pending_by_evidence(items.map(&:id).uniq)
    return {} if by_item.empty?

    cells = Evidence::CellContextResolver.new(by_item.values.flatten).by_id
    by_item.transform_values do |suggestions|
      { suggestions: suggestions, cells: suggestions.to_h { |s| [ s.id, cells.fetch(s.id, {}) ] } }
    end
  end

  # Whether "Suggest again" can do anything for this tenant.
  #
  # @param tenant [Tenant]
  # @return [Boolean]
  def self.regenerable?(tenant)
    tenant.present? && tenant.evidence_suggestions_enabled? && Evidence::SuggestionModel.configured?
  end
end
