# frozen_string_literal: true

# Sets who a person reports to in a scenario, as a ReportingLineSet change
# [#256](https://github.com/espaliahq/espalia/issues/256): a person, a
# position (a vacant manager seat), or nobody. Every check runs under the
# plan's lock, after the editor check. Fit is read, not refused: a line to a
# closed position or to someone who has left still resolves. A loop is
# refused against the scenario as it resolves now; one an ancestor's later
# edit makes still resolves, and walking up stops at the repeat.
class Operations::TeamPlanning::SetReportingLine < Operations::Base
  include Operations::TeamPlanning::ChangeWrite

  LINE = ::TeamPlanning::Events::ReportingLineSet

  description "Set who a person reports to in a scenario of a Team Planning plan: a manager (manager_id), an open " \
              "manager position (manager_position_id), so a team whose manager is being hired reports to that " \
              "seat, or neither for no manager. Never both, never the person themself, and never a line that " \
              "would make a loop. Reporting lines are independent of units: placing someone never moves their " \
              "line. Steps after the scenario, and its alternatives, inherit the line unless they set it again. " \
              "Refused unless the caller is one of the plan's editors."
  category :write
  approval :mcp_client

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true, schema: { description: "The scenario, or the plan's id for the baseline." }
  parameter :person_id, String, required: true
  parameter :manager_id, String, schema: { description: "The person they report to. Give this or manager_position_id, or neither." }
  parameter :manager_position_id, String, schema: { description: "A position the scenario has, for a manager being hired." }

  # @return [Hash] `{ plan_id, scenario_id, person_id, manager_id, manager_position_id }`
  def perform
    person_id = uuid!(:person_id)
    stored = nil
    set_change!(LINE, subject_id: person_id, end_state: params.slice(*LINE::TARGETS)) do |plan|
      stored = LINE.end_state(params.slice(*LINE::TARGETS))
      stored.compact.each_key { uuid!(it) }
      raise Operations::Base::ParameterError, "No such person" unless person?(person_id)

      line!(plan, person_id, **stored)
    end

    { plan_id: plan_id!, scenario_id: scenario_id!(:scenario_id), person_id:, **stored }
  end

  private

  def line!(plan, person_id, manager_id:, manager_position_id:)
    if manager_position_id && !winning_change(plan, manager_position_id, ::TeamPlanning::Events::PositionSet.facet)
      raise Operations::Base::ParameterError, "This scenario has no such position"
    end
    if manager_id
      raise Operations::Base::ParameterError, "A person can't report to themself" if manager_id == person_id
      raise Operations::Base::ParameterError, "No such manager" unless person?(manager_id)
    end
    return unless (manager_id || manager_position_id) && loop?(plan, person_id, manager_id:, manager_position_id:)

    raise Operations::Base::ParameterError, "That line makes a loop: the manager already reports up to this person"
  end

  # Walks up from the manager, or from the people holding the manager
  # position, through each line, looking for the person.
  def loop?(plan, person_id, manager_id:, manager_position_id:)
    record = ::TeamPlanningPlan.find(plan_id!)
    map = ::TeamPlanning::Resolution.new(context:, plan: record, scenario_id: scenario_id!(:scenario_id)).structure(plan)
    lines = map.people.to_h { [ it.id, it.line ] }
    holders = map.occupants.transform_values { it.map { |holder, _| holder.id } }
    above = manager_id ? [ manager_id ] : holders.fetch(manager_position_id, [])
    seen = Set.new
    while (id = above.shift)
      return true if id == person_id
      next unless seen.add?(id) && (line = lines[id])

      above.concat(line.person_id ? [ line.person_id ] : holders.fetch(line.position_id, []))
    end
    false
  end

  def person?(id) = ::Person.exists?(tenant_id: ActsAsTenant.current_tenant&.id, id:)
end
