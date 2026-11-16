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
              "who did it and when. action is set, pin, clear, undo, redo, note, rebase, move, dates, archive, restore, close or reopen; an undo or redo names the entry " \
              "it reverses in reverses_event_id, and a note names the change it notes in noted_event_id, with " \
              "no note when it cleared it. The baseline's history also lists each update to today as action rebase, " \
              "whose end_state holds base_on, previous_base_on and the conflicts it carried forward, and each time the plan " \
              "was archived or restored as action archive or restore. A step's history lists each time it was closed or reopened " \
              "as action close or reopen, with who and when and no end_state. " \
              "A set or pin that settled a conflict an update carried forward has settles: { since, choice }, choice " \
              "plan or reality, so keeping the plan reads apart from an ordinary edit. " \
              "A move is an entry of the step a change moved to, whose end_state holds from_scenario_id and direction, " \
              "and the entries of that change move with it. " \
              "A dates entry is a step's new period, whose end_state holds starts_on, ends_on, previous_ends_on and, " \
              "unless written before a first step could start later, previous_starts_on. A null ends_on or previous_ends_on " \
              "means no end date. A step after one with no end date closes it, a dates entry of the closed step " \
              "whose end_state holds only ends_on and a null previous_ends_on. An undo or redo of a dates entry holds the " \
              "period it brings back in the same fields. " \
              "An entry that stands undone says who undid it. A change, pin or note entry shows its note " \
              "as note: { value }, or { removed: true } once the plan is deleted. A note on a pay change reaches only a member with the see-pay right; anyone else gets no note on it, " \
              "and no note entry for it. A budget line's amount, currency and period are pay too: anyone else gets its " \
              "entries without them, so a priced line reads as one with a head count alone. Any other value " \
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
    see_pay = PlanPolicy.new(context, plan).see_pay?
    entries = TeamPlanningHistoryEntry.where(plan_id: plan.id, scenario_id:).order(:position)
    hidden = Operations::TeamPlanning::ChangeNote.hidden_facets(see_pay:)
    entries = entries.where.not(action: "note").or(entries.where.not(facet: hidden)) if hidden.any?
    entries = entries.offset((page - 1) * per_page).limit(per_page + 1).to_a
    next_page = entries.size > per_page
    entries = entries.first(per_page)
    names = Person.where(id: entries.flat_map { [ it.actor_id, it.undone_by_id ] }.compact.uniq).pluck(:id, :name).to_h
    { plan_id: plan.id, scenario_id:, page:, next_page:, entries: entries.map { entry(it, names, see_pay) } }
  end

  private

  def entry(row, names, see_pay)
    {
      event_id: row.id, action: row.action, subject_id: row.subject_id, facet: row.facet,
      kind: row.kind&.demodulize&.underscore,
      end_state: Operations::TeamPlanning::LineFigures.end_state(row.end_state, facet: row.facet, see_pay:),
      sealed_fields: Operations::TeamPlanning::LineFigures.sealed_fields(row.sealed_fields, facet: row.facet, see_pay:),
      pinned_from: (row.action == "pin" ? { scenario_id: row.pinned_from_scenario_id, event_id: row.pinned_from_event_id } : nil),
      reverses_event_id: row.reverses_event_id, noted_event_id: row.noted_event_id, note: Operations::TeamPlanning::ChangeNote.payload(row.note, facet: row.facet, see_pay:),
      settles: row.settles, by: person(row.actor_id, names), at: row.at.utc.iso8601,
      undone: (row.undone? ? { by: person(row.undone_by_id, names), at: row.undone_at.utc.iso8601 } : nil)
    }.compact
  end

  def person(id, names) = { person_id: id, name: names.fetch(id, Person::FORMER_MEMBER) }
end
