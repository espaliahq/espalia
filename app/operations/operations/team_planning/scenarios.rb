# frozen_string_literal: true

# A plan's scenarios: the baseline, and each scenario with its parent,
# relation and the period the tree gives it.
#
# Any member may list them, the baseline first with the plan's id
# [#208](https://github.com/espaliahq/espalia/issues/208).
class Operations::TeamPlanning::Scenarios < Operations::Base
  include Operations::TeamPlanning::PlanRead

  # The aggregate refuses a replaced step as part of the closed one, which reads wrong on a scenario not taken.
  NOT_TAKEN = "This scenario wasn't taken: another step closed in its place"

  description "List the scenarios of a Team Planning plan the caller is in. The baseline comes first: its id is " \
              "the plan's, it stands on the base date and has no parent, relation or end. Each other scenario has " \
              "its parent_id, its relation ('then' follows the parent, 'instead' is an alternative to it, 'on' is " \
              "the rest of a split step, sitting on its agreed part), its " \
              "period, what it is for, if an editor has said, and changes: how many subjects and facets it still changes, " \
              "the count its Removed scenarios entry keeps once it is removed. state says where it stands on the timeline: " \
              "'closed' for a step closed with team_planning_close_step, with closed_on, the UTC day it was closed, and closed_by; " \
              "'not_taken' for a scenario a closed step replaced; 'ready_to_close' for the step that can close next; " \
              "otherwise 'open'. Every scenario but the one ready carries not_closable_because, saying why it can't close; the baseline is always 'open'. " \
              "Refused, as an unknown plan, unless the caller is a member."
  category :read
  approval :none

  parameter :plan_id, String, required: true

  # @return [Hash] `{ plan_id, scenarios: [{ scenario_id, parent_id, relation, name, description, starts_on, ends_on, changes,
  #   state, closed_on, closed_by, not_closable_because }] }`
  def perform
    plan = plan!
    rows = TeamPlanningScenario.where(plan_id: plan.id).order(:created_at, :id).partition(&:baseline?).flatten
    held = TeamPlanningHistoryEntry.changes_held(rows.map(&:id))
    aggregate = ::TeamPlanning::Repository.new.load_plan(plan.id)
    names = Person.where(id: rows.filter_map(&:closed_by_id).uniq).pluck(:id, :name).to_h
    scenarios = rows.map do |row|
      { scenario_id: row.id, parent_id: row.parent_id, relation: row.relation, name: row.name&.reveal, description: row.description&.reveal,
        starts_on: row.starts_on.iso8601, ends_on: row.ends_on&.iso8601, changes: held.fetch(row.id, 0),
        **standing(plan, aggregate, row, names) }
    end
    { plan_id: plan.id, scenarios: }
  end

  private

  def standing(plan, aggregate, row, names)
    why = if row.baseline? then "The baseline can't be closed"
    elsif plan.archived? then ::TeamPlanning::PlanAggregate::ARCHIVED
    else aggregate.not_closable_because(row.id, Time.now.utc.to_date)
    end
    closed = !row.baseline? && aggregate.closed?(row.id)
    state = if closed then "closed"
    elsif !row.baseline? && aggregate.frozen?(row.id) then "not_taken"
    else why ? "open" : "ready_to_close"
    end
    why = NOT_TAKEN if state == "not_taken"
    by = row.closed_by_id if closed
    { state:, closed_on: (row.closed_on&.iso8601 if closed), not_closable_because: why,
      closed_by: by && { person_id: by, name: names.fetch(by, Person::FORMER_MEMBER) } }
  end
end
