# frozen_string_literal: true

# A scenario's history: every change, pin and clear it made, every undo and
# redo of one and every rewrite of a note, oldest first, with who did each
# [#243](https://github.com/espaliahq/espalia/issues/243),
# [#273](https://github.com/espaliahq/espalia/issues/273).
class Operations::TeamPlanning::History < Operations::Base
  include Operations::TeamPlanning::PlanRead

  # Rows a page holds.
  PER_PAGE = 100

  # @return [Integer] rows a page holds; a seam for tests
  def self.per_page = PER_PAGE

  description "List the history of a scenario of a Team Planning plan the caller is in, oldest first, " \
              "#{PER_PAGE} entries a page, with next_page true when another follows: every " \
              "change it set, pin and clear it made, every undo and redo of one, and every note written on one, with " \
              "who did it and when. action is set, pin, clear, undo, redo, note, rebase or move; an undo or redo names the entry " \
              "it reverses in reverses_event_id, and a note names the change it notes in noted_event_id, with " \
              "no note when it cleared it. The baseline's history also lists each update to today as action rebase, " \
              "whose end_state holds base_on, previous_base_on and the conflicts it carried forward. " \
              "A set or pin that settled a conflict an update carried forward has settles: { since, choice }, choice " \
              "plan or reality, so keeping the plan reads apart from an ordinary edit. " \
              "A move is an entry of the step a change moved to, whose end_state holds from_scenario_id and direction, " \
              "and the entries of that change move with it. " \
              "An entry that stands undone says who undid it. A change, pin or note entry shows its note " \
              "as note: { value }, or { removed: true } once the plan is deleted. Any other value " \
              "that can be erased is never shown here: sealed_fields names any such field. A forgotten person reads as " \
              "\"#{Person::FORMER_MEMBER}\". Refused, as an unknown plan, unless the caller is a member."
  category :read
  approval :none

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true
  parameter :page, Integer, required: false

  # @return [Hash] `{ plan_id, scenario_id, page, next_page, entries: [...] }`
  def perform
    plan = plan!
    scenario_id = scenario_id!(:scenario_id)
    unless TeamPlanningScenario.exists?(plan_id: plan.id, id: scenario_id)
      raise Operations::Base::ParameterError, "This plan has no such scenario"
    end

    page = params[:page].to_i.clamp(1..)
    per_page = self.class.per_page
    entries = TeamPlanningHistoryEntry.where(plan_id: plan.id, scenario_id:).order(:position)
                                      .offset((page - 1) * per_page).limit(per_page + 1).to_a
    next_page = entries.size > per_page
    entries = entries.first(per_page)
    names = Person.where(id: entries.flat_map { [ it.actor_id, it.undone_by_id ] }.compact.uniq).pluck(:id, :name).to_h
    { plan_id: plan.id, scenario_id:, page:, next_page:, entries: entries.map { entry(it, names) } }
  end

  private

  def entry(row, names)
    {
      event_id: row.id, action: row.action, subject_id: row.subject_id, facet: row.facet,
      kind: row.kind&.demodulize&.underscore, end_state: row.end_state, sealed_fields: row.sealed_fields,
      pinned_from: (row.action == "pin" ? { scenario_id: row.pinned_from_scenario_id, event_id: row.pinned_from_event_id } : nil),
      reverses_event_id: row.reverses_event_id, noted_event_id: row.noted_event_id, note: Operations::TeamPlanning::MapPayload.sealed(row.note),
      settles: row.settles, by: person(row.actor_id, names), at: row.at.utc.iso8601,
      undone: (row.undone? ? { by: person(row.undone_by_id, names), at: row.undone_at.utc.iso8601 } : nil)
    }.compact
  end

  def person(id, names) = { person_id: id, name: names.fetch(id, Person::FORMER_MEMBER) }
end
