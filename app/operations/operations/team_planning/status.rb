# frozen_string_literal: true

# Where each of a scenario's planned changes stands against the Org Graph
# today ([#235](https://github.com/espaliahq/espalia/issues/235)), compared
# by `TeamPlanning::Status` on every read. A change is compared only when the
# Org Graph could show it; any other reads plan_only. Walked by the privacy
# test and the forgotten-person audit.
class Operations::TeamPlanning::Status < Operations::Base
  include Operations::TeamPlanning::PlanRead

  description "Get the status of each planned change in a scenario of a Team Planning plan the caller is in, " \
              "held against the Org Graph today (a UTC day, as known now). There is one status per subject and " \
              "facet the scenario resolves, from its own changes and those it inherits from the scenarios it " \
              "follows; scenario_id says which scenario made it (the plan_id is the baseline). 'done' when today " \
              "reads the planned end state, 'pending' when today still reads what the plan's base held or what " \
              "the step before plans, 'conflicting' when it reads none of these, 'unknown' when the plan's value " \
              "was private and has since been removed, and 'plan_only' for a change the Org Graph never holds, " \
              "such as a rule, a position, a capacity, a budget line, a hire the plan adds or a person's pay: it is " \
              "never compared, so it is no Org Graph work still to do, and has no sources. Before the plan's base " \
              "date nothing reads conflicting. A " \
              "conflict an update to today carried forward still reads 'conflicting', with since the day of the " \
              "update that first found it, while the scenario still resolves to the same change: a set, pin, " \
              "clear or undo ends it. A change that reads done, unknown or plan_only keeps that status; otherwise since is " \
              "null. Each status carries `sources`, who supplies what the change moves: the provider of a " \
              "person fact (level, manager, leaving), or of the units an assignment, unit or succession touches, " \
              "today and as planned (\"espalia\" for one Espalia supplies, or an HRIS such as \"hibob\"). A person's placements are one facet, so a placement list is " \
              "done only when the whole list matches. The Org Graph can't say which position someone fills, only " \
              "where they are, so a placement in a position is done once the person is in the position's unit at " \
              "its allocation, with its role only when the plan names one. A unit retirement is " \
              "done once the Org Graph has retired the unit. A unit succession is held against every succession " \
              "the Org Graph recorded since the base that shares a planned predecessor, joined: done when they " \
              "join to the planned sides, conflicting when they don't. A departure is done once the Org Graph has " \
              "the person leave, and pending while they stay. A withdrawn departure carries staying: true; it is done while " \
              "the person stays, and conflicting once the Org Graph has them leave. Subjects are named by id, and `names` maps each the Org Graph " \
              "holds to a name; a forgotten person reads as \"#{Person::FORMER_MEMBER}\", and a subject only the " \
              "plan holds has none. A status whose change carries a note has it as note: { value }, or { removed: true } " \
              "once erased. A note on a pay change reaches only a member with the see-pay right; anyone else gets no note on it. " \
              "clearable is true on a status the caller may hand back to what the step before gives it with " \
              "team_planning_clear_change: an editor's, on a change the scenario makes itself, never on the " \
              "baseline, never on a pay change or on a budget line that carries an amount without the see-pay " \
              "right, and never about someone or something " \
              "outside the units a scoped plan covers. #{UNCHECKED} Refused, as an unknown plan, unless " \
              "the caller is a member."
  category :read
  approval :none

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true, schema: { description: "The scenario, or the plan's id for the baseline." }

  # @return [Hash] `{ plan_id, scenario_id, checked, on, statuses, names }`; an archived plan's has
  #   `{ plan_id, scenario_id, checked, archived_on, note, statuses, names }`
  def perform
    plan = plan!
    scenario_id = scenario_id!(:scenario_id)
    if plan.archived?
      known_scenario!(plan, scenario_id)
      return { plan_id: plan.id, scenario_id:, **checked(plan), statuses: [], names: {} }
    end

    report = refusing_bad_plans { ::TeamPlanning::Status.new(context:, plan:, scenario_id:).call }
    notes = notes_of(plan, report.statuses.map(&:change_id))
    see_pay = PlanPolicy.new(context, plan).see_pay?
    clearable = clearable(plan, scenario_id, see_pay)
    { plan_id: plan.id, scenario_id:, **checked(plan), on: report.on.iso8601,
      statuses: report.statuses.map do
        status_row(it, ::Operations::TeamPlanning::ChangeNote.payload(notes[it.change_id], facet: it.facet, see_pay:), clearable.call(it))
      end,
      names: report.names }
  end

  private

  # @return [Proc] whether the caller may clear a status's change
  def clearable(plan, scenario_id, see_pay)
    return ->(_) { false } if scenario_id == plan.id || PlanPolicy.frozen?(plan) || !PlanPolicy.new(context, plan).update?

    outside = nil
    lambda do |entry|
      entry.scenario_id == scenario_id && (see_pay || stays_theirs?(plan, scenario_id, entry)) &&
        !(outside ||= outside_scope(plan, scenario_id)).include?(entry.subject_id)
    end
  end

  # Without the see-pay right, a pay change and a change on a budget line that
  # carries an amount are not the caller's to clear.
  def stays_theirs?(plan, scenario_id, entry)
    return false if entry.facet == ::TeamPlanning::Events::PlanDataSet::PAY_FACET

    !::TeamPlanning::LineMoney.priced?(aggregate_of(plan), scenario_id, entry.subject_id, entry.facet)
  end

  def aggregate_of(plan) = @aggregate ||= ::TeamPlanning::Repository.new.load_plan(plan.id)

  def outside_scope(plan, scenario_id)
    return Set.new if plan.scope_unit_ids.blank?

    map = ::TeamPlanning::Resolution.new(context:, plan:, scenario_id:).structure
    map.outside_ids | map.cut_ids
  end

  # A change's note is rewritten apart from it, so it is read off the override
  # the change projects, which holds the latest.
  def notes_of(plan, change_ids)
    TeamPlanningOverride.where(plan_id: plan.id, event_id: change_ids).filter_map { [ it.event_id, it.note ] if it.note }.to_h
  end

  def status_row(entry, note, clearable)
    entry.to_h.except(:staying).merge(status: entry.status.to_s, since: entry.since&.iso8601, clearable:,
                                      **({ staying: true } if entry.staying),
                                      **({ note: } if note))
  end
end
