# frozen_string_literal: true

# Something the last HRIS sync read and would not write, kept until a sync
# no longer reads it, so an admin sees it between syncs.
#
# The one kind so far is +in_structure+: the HRIS places a unit inside a
# unit's own structure (#494), whose types aren't the HRIS's to use, so
# {Hris::LevelMirror} leaves the unit where it was and records why. The sync
# owns these rows; nothing projects them.
#
class HrisSyncIssue < ApplicationRecord
  acts_as_tenant :tenant

  belongs_to :tenant

  KINDS = %w[in_structure].freeze

  # An issue with the units it names, loaded for display.
  Row = Data.define(:issue, :unit, :parent, :structure_unit)

  # @param scope [ActiveRecord::Relation] the issues to show
  # @return [Array<Row>] oldest first, each with its units, any of which may
  #   be nil once the unit is gone
  def self.rows(scope = all)
    issues = scope.order(:first_seen_on, :unit_id).to_a
    units = OrgUnit.where(id: issues.flat_map { [ it.unit_id, it.parent_id, it.structure_unit_id ] }.compact.uniq).index_by(&:id)
    issues.map { Row.new(issue: it, unit: units[it.unit_id], parent: units[it.parent_id], structure_unit: units[it.structure_unit_id]) }
  end

  validates :provider, :unit_id, :first_seen_on, :last_seen_on, presence: true
  validates :kind, inclusion: { in: KINDS }

  # Replaces the in-structure issues for the units a sync read: the ones it
  # reported stay or start, keeping the day each was first seen, and the
  # rest go.
  #
  # @param provider [String]
  # @param unit_ids [Array<String>] every unit at the levels the sync read
  # @param reported [Array<Hash>] the result's :units_in_structures
  # @param today [Date]
  # @return [void]
  def self.replace_in_structure(provider:, unit_ids:, reported:, today:)
    by_unit = reported.index_by { it[:unit_id] }
    existing = where(kind: "in_structure", unit_id: unit_ids | by_unit.keys).index_by(&:unit_id)
    existing.each { |unit_id, issue| issue.destroy! unless by_unit.key?(unit_id) }
    by_unit.each do |unit_id, issue|
      (existing[unit_id] || new(kind: "in_structure", unit_id:, first_seen_on: today))
        .update!(provider:, parent_id: issue[:parent_id], structure_unit_id: issue[:structure_unit_id], last_seen_on: today)
    end
  end
end
