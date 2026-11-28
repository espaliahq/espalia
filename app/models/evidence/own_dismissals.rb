# frozen_string_literal: true

# The placement suggestions a viewer dismissed under a set of hub items, with
# each one's cell name and reason. The hub shows a viewer only their own,
# whatever else they may see, so each row goes through
# {Assessments::SuggestionDismissalVisibility} with `viewer_sees_all: false`.
#
# It reads the suggestions table, never a stream. Feedback about a forgotten
# person is left out in the same query, so that person's rows are never read.
class Evidence::OwnDismissals
  NONE = { dismissals: [], cells: {} }.freeze

  # @param items [Array<EvidenceItem>]
  # @param viewer_person_id [String, nil]
  # @return [Hash{String => Hash}] item id => { dismissals:, cells: }, only for
  #   items with a dismissal by the viewer; cells maps a suggestion id to
  #   { name:, level_code: }
  def self.for(items, viewer_person_id)
    return {} if items.empty?

    dismissals = EvidencePlacementSuggestion
      .where(evidence_id: items.map(&:id).uniq, status: "dismissed")
      .where.not(person_id: Person.forgotten.select(:id))
      .order(:decided_at, :id)
      .select { |row| visible_to?(row, viewer_person_id) }
    return {} if dismissals.empty?

    cells = cell_names(dismissals)
    dismissals.group_by(&:evidence_id).transform_values do |rows|
      { dismissals: rows, cells: rows.to_h { |row| [ row.id, cells.fetch(row.id) ] } }
    end
  end

  def self.visible_to?(row, viewer_person_id)
    Assessments::SuggestionDismissalVisibility.visible?(
      dismissed_by_id: row.decided_by_id, viewer_person_id: viewer_person_id, viewer_sees_all: false
    )
  end
  private_class_method :visible_to?

  # Capability name and the assessee's level code, one query per framework and per assessee.
  def self.cell_names(rows)
    names = rows.group_by(&:framework_id).each_with_object({}) do |(framework_id, group), acc|
      FrameworkState::Capability.joins(:category)
        .merge(FrameworkState::CapabilityCategory.where(framework_id: framework_id))
        .where(stable_id: group.map(&:capability_stable_id).uniq)
        .pluck(:stable_id, :name).each { |stable_id, name| acc[[ framework_id, stable_id ]] = name }
    end
    codes = rows.map { |row| [ row.framework_id, row.person_id ] }.uniq.each_with_object({}) do |(framework_id, person_id), acc|
      role_id = PersonFrameworkAssignment.where(framework_id: framework_id, person_id: person_id).pick(:role_id)
      acc[[ framework_id, person_id ]] = FrameworkState::Level.where(role_id: role_id).pluck(:ordinal, :code).to_h
    end
    rows.to_h do |row|
      [ row.id, { name: names[[ row.framework_id, row.capability_stable_id ]],
                  level_code: codes[[ row.framework_id, row.person_id ]][row.level_ordinal] } ]
    end
  end
  private_class_method :cell_names
end
