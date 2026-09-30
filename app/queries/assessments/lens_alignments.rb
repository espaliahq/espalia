# frozen_string_literal: true

# The alignments started against roles other than home (ADR-22), per
# participation — what the list cards and the home page show beside the
# home status, so the assessee sees "Aligning · PM3" without opening a lens.
#
# @example
#   Assessments::LensAlignments.for(cycle_ids: [ cid ], person_ids: [ pid ])
#   # => { [cid, pid] => [#<Entry code="PM3" status="aligning" …>] }
class Assessments::LensAlignments
  # Duck-types with {Assessments::Disclosure::Alignment} where the chips
  # read it: `role_id`, `code`, `label`, `level_ordinal`, `status`.
  Entry = Data.define(:role_id, :code, :label, :level_ordinal, :status)

  # @param cycle_ids [Array<String>]
  # @param person_ids [Array<String>]
  # @return [Hash{Array(String, String) => Array<Entry>}]
  def self.for(cycle_ids:, person_ids:)
    return {} if cycle_ids.empty? || person_ids.empty?

    rows = AssessmentCycleRoleAlignment.lens.where(cycle_id: cycle_ids, person_id: person_ids)
      .order(:alignment_started_at).to_a
    roles = FrameworkState::Role.where(role_id: rows.map(&:role_id).uniq).index_by(&:role_id)
    rows.each_with_object(Hash.new { |h, k| h[k] = [] }) do |row, out|
      role = roles[row.role_id]
      next unless role

      code = "#{role.code}#{row.level_ordinal}"
      out[[ row.cycle_id, row.person_id ]] << Entry.new(
        role_id: row.role_id, code: code, label: "#{role.name} · #{code}",
        level_ordinal: row.level_ordinal, status: row.status
      )
    end
  end
end
