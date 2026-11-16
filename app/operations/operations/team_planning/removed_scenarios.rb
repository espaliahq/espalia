# frozen_string_literal: true

# The scenarios removed from a plan, newest first: who removed each, when,
# its name and period as they stood, and how many changes it still held
# [#340](https://github.com/espaliahq/espalia/issues/340).
#
# An entry names no subject, facet, value or note, and its count is one
# number for every facet, pay included. So a member without the see-pay
# right, or one whose plan is scoped, reads the same entry as anyone else.
# A field about a subject or a facet would need clearance first.
class Operations::TeamPlanning::RemovedScenarios < Operations::Base
  include Operations::TeamPlanning::PlanRead

  # Rows a page holds.
  PER_PAGE = 100

  # @return [Integer] rows a page holds; a seam for tests
  def self.per_page = PER_PAGE

  description "List the scenarios removed from a Team Planning plan the caller is in, newest first, #{PER_PAGE} a page, " \
              "with next_page true when another follows and total counting them all. A page past the last reads as the last. Each has its scenario_id, its name, its relation ('then', " \
              "'instead' or 'on') and the period it had when removed (a null ends_on means no end date), who removed it " \
              "and when, and changes: how many changes it still held, one for each subject and facet it changed, " \
              "counting pay and anything else the caller can't see, with undone and cleared ones left out. Nothing " \
              "about those changes is listed. A removed scenario's own history is gone. A forgotten person reads as " \
              "\"#{Person::FORMER_MEMBER}\". Refused, as an unknown plan, unless the caller is a member."
  category :read
  approval :none

  parameter :plan_id, String, required: true
  parameter :page, Integer, required: false

  # @return [Hash] `{ plan_id, page, next_page, total, removed: [{ scenario_id, name, relation, starts_on, ends_on, changes,
  #   removed_by: { person_id, name }, removed_at }] }`
  def perform
    plan = plan!
    per_page = self.class.per_page
    scope = TeamPlanningRemovedScenario.where(plan_id: plan.id)
    total = scope.count
    page = params[:page].to_i.clamp(1, [ total.ceildiv(per_page), 1 ].max)
    rows = scope.order(removed_at: :desc, id: :desc).offset((page - 1) * per_page).limit(per_page + 1).to_a
    next_page = rows.size > per_page
    rows = rows.first(per_page)
    held = TeamPlanningRemovedScenarioTally.where(id: rows.map(&:id)).to_h { [ it.id, it.changes_held ] }
    names = Person.where(id: rows.map(&:removed_by_id).compact.uniq).pluck(:id, :name).to_h
    { plan_id: plan.id, page:, next_page:, total:, removed: rows.map { entry(it, held, names) } }
  end

  private

  def entry(row, held, names)
    { scenario_id: row.id, name: row.name&.reveal, relation: row.relation, starts_on: row.starts_on&.iso8601,
      ends_on: row.ends_on&.iso8601, changes: held.fetch(row.id, 0),
      removed_by: { person_id: row.removed_by_id, name: names.fetch(row.removed_by_id, Person::FORMER_MEMBER) },
      removed_at: row.removed_at.utc.iso8601 }
  end
end
