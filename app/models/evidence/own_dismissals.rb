# frozen_string_literal: true

# The placement suggestions a viewer dismissed under a set of hub items, with
# each one's cell name and reason. The hub shows a viewer only their own,
# whatever else they may see, so this asks {Assessments::SuggestionDismissalVisibility}
# with `viewer_sees_all: false`.
#
# It reads the suggestions table, never a stream. Feedback about a forgotten
# person is left out in the same query, so that person's rows are never read.
class Evidence::OwnDismissals
  NONE = { dismissals: [], cells: {} }.freeze

  # @param items [Array<EvidenceItem>]
  # @param viewer_person_id [String, nil]
  # @return [Hash{String => Hash}] item id => { dismissals:, cells: }, only for
  #   items with a dismissal by the viewer
  def self.for(items, viewer_person_id)
    return {} if items.empty? || viewer_person_id.blank?

    dismissals = EvidencePlacementSuggestion
      .where(evidence_id: items.map(&:id).uniq, status: "dismissed", decided_by_id: viewer_person_id)
      .where.not(person_id: Person.forgotten.select(:id))
      .order(:decided_at)
      .select { |row| visible_to?(row, viewer_person_id) }
    return {} if dismissals.empty?

    cells = Evidence::CellContextResolver.new(dismissals).by_id
    dismissals.group_by(&:evidence_id).transform_values do |rows|
      { dismissals: rows, cells: rows.to_h { |row| [ row.id, cells.fetch(row.id, {}) ] } }
    end
  end

  def self.visible_to?(row, viewer_person_id)
    Assessments::SuggestionDismissalVisibility.visible?(
      dismissed_by_id: row.decided_by_id, viewer_person_id: viewer_person_id, viewer_sees_all: false
    )
  end
  private_class_method :visible_to?
end
