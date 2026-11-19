# frozen_string_literal: true

# What the Org Graph has learned since a plan's base, and what each change
# meets in the plan ([#234](https://github.com/espaliahq/espalia/issues/234)).
# A kind says which changes move its facet through
# `TeamPlanning::Events::Change.subject_moved_by`. Walked by the privacy test
# and the forgotten-person audit.
class Operations::TeamPlanning::Drift < Operations::Base
  include Operations::TeamPlanning::PlanRead

  description "Get the drift of a Team Planning plan the caller is in: every change the Org Graph learned " \
              "on or after the plan's base date, up to today (days in the tenant's time zone), whatever day it took effect, in effective " \
              "date order, as org_graph_changes_between by \"learned\" gives them for from (the day before the base " \
              "date) and to (today). A change it no longer believes comes back withdrawn. Each change carries `meets`, the " \
              "plan's latest change to the facet it moves, one per scenario that holds one (a scenario_id equal " \
              "to the plan_id is the baseline), `from_plan`, true when the change was applied from this plan, and `sources`, who supplies what it " \
              "moves: the provider of a person fact, whoever supplied a membership, or the providers of the units a unit or succession touches " \
              "(\"espalia\" for one Espalia supplies, or an HRIS such as \"hibob\"). " \
              "A person's placements are one facet, so a move in one placement meets the plan's whole list. " \
              "A plan covering some units lists only changes about the people and units it covers, at its base, in any " \
              "scenario, or placed in one of them since, including by a move known before the base that takes effect after it. " \
              "Such a move decides coverage from its own day but is not listed. A change that takes one of them out, or a covered person now reporting " \
              "to someone the plan can't show, keeps the fact and nulls what lies outside; a joiner keeps only the units and manager " \
              "the plan covers. A structure a unit declares or withdraws retypes every unit beneath it under one cause, " \
              "and reads as one change, `structure_declared` or `structure_withdrawn`, in the place of its first type change: " \
              "`event_id` is that cause, the same on every read, `unit_ids` the retyped units the plan covers and `count` how many. " \
              "Its `unit_id` is the declaring unit, null with \"unit_id\" in `outside` when the plan doesn't cover it. " \
              "A change that took effect before the base nulls `before`. `outside` lists the fields nulled or trimmed. " \
              "People are named by id, and `names` maps every person and unit id the changes name to a name, but a scoped plan " \
              "names only the units it covers today; a forgotten " \
              "person reads as \"#{Person::FORMER_MEMBER}\". #{UNCHECKED} Refused, as an unknown plan, unless the caller is a member."
  category :read
  approval :none

  parameter :plan_id, String, required: true

  # @param report [TeamPlanning::Drift::Report]
  # @return [Hash] `{ from, to, changes, names }`, the shape team_planning_rebase_preview shares
  def self.payload(report)
    { from: report.from.iso8601, to: report.to.iso8601, changes: report.changes.map { serialize(it) }, names: names_for(report) }
  end

  # Every id the changes name, so a client never meets an id it can't name.
  def self.names_for(report)
    ids = report.changes.flat_map { [ it.change.person_id, it.change.before&.dig("manager_id"), it.change.after&.dig("manager_id") ] }
    unit_ids = report.changes.flat_map { [ it.change.unit_id, it.change.from_unit_id, *it.group&.unit_ids ] }.compact.uniq
    report.names.slice(*unit_ids).merge(ids.compact.uniq.index_with { report.name_of(it) })
  end

  def self.serialize(drifted)
    change = drifted.change
    change.to_h.merge(kind: change.kind.to_s, effective_on: change.effective_on.iso8601,
                      learned_at: change.learned_at&.utc&.iso8601,
                      from_plan: drifted.from_plan, meets: drifted.meets.map(&:to_h), sources: drifted.sources,
                      outside: drifted.outside, **group_fields(drifted.group))
  end
  def self.group_fields(group) = group ? { unit_ids: group.unit_ids, count: group.unit_ids.size } : {}
  private_class_method :names_for, :serialize, :group_fields

  # @return [Hash] `{ plan_id, checked, from, to, changes, names }`; an archived plan's has
  #   `{ plan_id, checked, archived_on, note, changes, names }`
  def perform
    plan = plan!
    return { plan_id: plan.id, **checked(plan), changes: [], names: {} } if plan.archived?

    { plan_id: plan.id, **checked(plan), **self.class.payload(::TeamPlanning::Drift.new(context:, plan:).call) }
  end
end
