# frozen_string_literal: true

# What the last HRIS sync read and would not write, the HRIS page's Sync
# issues card (#494). Units only, never people.
class Operations::Integrations::HrisSyncIssues < Operations::Base
  description "List what the HRIS sync read and would not write, oldest first. The one kind so far is " \
              "in_structure: the HRIS places a unit under a parent inside a unit's own structure, whose " \
              "types aren't the HRIS's to use, so the sync left the unit where it was. Each issue names " \
              "the unit, the parent the HRIS gave it and the unit whose structure that is, by id and " \
              "name, with the days a sync first and last read it. An issue clears once a sync no longer " \
              "reads it. Admins only."
  category :read
  approval :none

  def policy_check
    authorize :integrations, :show?
  end

  # @return [Hash] the issues
  def perform
    { issues: HrisSyncIssue.rows.map { |row| issue_payload(row) } }
  end

  private

  def issue_payload(row)
    issue = row.issue
    {
      kind: issue.kind,
      provider: issue.provider,
      unit_id: issue.unit_id,
      unit_name: row.unit&.name,
      parent_id: issue.parent_id,
      parent_name: row.parent&.name,
      structure_unit_id: issue.structure_unit_id,
      structure_unit_name: row.structure_unit&.name,
      first_seen_on: issue.first_seen_on.iso8601,
      last_seen_on: issue.last_seen_on.iso8601
    }
  end
end
