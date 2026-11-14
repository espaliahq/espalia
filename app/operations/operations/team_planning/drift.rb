# frozen_string_literal: true

# What the Org Graph has learned since a plan's base, and what each change
# meets in the plan.
class Operations::TeamPlanning::Drift < Operations::Base
  include Operations::TeamPlanning::PlanRead

  description "Get the drift of a Team Planning plan the caller is in: every change the Org Graph learned " \
              "from the plan's base date to today (UTC days), whatever day it took effect, in effective date " \
              "order, as org_graph_changes_between by \"learned\" gives them. Each change carries `meets`, the " \
              "plan's latest change to the facet it moves, one per scenario that holds one (a scenario_id equal " \
              "to the plan_id is the baseline), and `from_plan`, true when the change was applied from this plan. " \
              "A person's placements are one facet, so a move in one placement meets the plan's whole list. " \
              "People are named by id, and `names` maps every person id the changes name to a name; a forgotten " \
              "person reads as \"#{Person::FORMER_MEMBER}\". Refused, as an unknown plan, unless the caller is a member."
  category :read
  approval :none

  parameter :plan_id, String, required: true

  # @return [Hash] `{ plan_id, from, to, changes, names }`
  def perform
    plan = plan!
    report = ::TeamPlanning::Drift.new(context:, plan:).call
    { plan_id: plan.id, from: report.from.iso8601, to: report.to.iso8601,
      changes: report.changes.map { serialize(it) },
      names: names_for(report) }
  end

  private

  # Every id the changes name, so a client never meets an id it can't name.
  def names_for(report)
    ids = report.changes.flat_map { [ it.change.person_id, it.change.before&.dig("manager_id"), it.change.after&.dig("manager_id") ] }
    ids.compact.uniq.index_with { report.name_of(it) }
  end

  def serialize(drifted)
    change = drifted.change
    change.to_h.merge(kind: change.kind.to_s, effective_on: change.effective_on.iso8601,
                      learned_at: change.learned_at&.utc&.iso8601,
                      from_plan: drifted.from_plan, meets: drifted.meets.map(&:to_h))
  end
end
