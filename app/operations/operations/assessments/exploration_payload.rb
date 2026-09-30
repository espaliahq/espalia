# frozen_string_literal: true

# The one shape a declared exploration (ADR-22) takes in every MCP payload —
# the list, the start / close results, `assessments_mine` and
# `assessments_get` — so an agent learns it once. `lens` carries the params
# that read the assessment against the target (`assessments_get`'s
# `as_role_id` / `as_level_ordinal`).
module Operations::Assessments::ExplorationPayload
  private

  # @param exploration [AssessmentExploration] with `target_role`,
  #   `started_by` and `closed_by` preloaded where a list is serialised
  # @return [Hash]
  def exploration_payload(exploration)
    role = exploration.target_role
    {
      id: exploration.id,
      status: exploration.status,
      target: { role_id: exploration.target_role_id, role_code: role&.code, role_name: role&.name,
                level_ordinal: exploration.target_level_ordinal, code: exploration.code },
      lens: { as_role_id: exploration.target_role_id, as_level_ordinal: exploration.target_level_ordinal },
      started_at: exploration.started_at&.iso8601,
      started_by: person_ref(exploration.started_by),
      note: exploration.start_note,
      closed_at: exploration.closed_at&.iso8601,
      closed_by: person_ref(exploration.closed_by),
      outcome: exploration.outcome,
      close_note: exploration.close_note
    }
  end

  def person_ref(person)
    person && { id: person.id, name: person.name }
  end
end
