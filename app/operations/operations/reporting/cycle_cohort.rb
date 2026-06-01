# frozen_string_literal: true

# Aggregate progress roll-up for an assessment cycle, shared by the web cohort
# view and the MCP server. Scoped to the caller's org subtree (admins/HR see the
# whole cycle). Exposes only counts/status — never rating values — matching the
# privacy invariant of the web view.
#
# Incremental disclosure: defaults to `summary` (funnel + counts + the most
# lagging subtree). Pass `mode: "full"` for the per-participant breakdown.
class Operations::Reporting::CycleCohort < Operations::Base
  description "Aggregate progress for an assessment cycle across the caller's org subtree " \
              "(admins see the whole cycle): the self/manager/aligned funnel, lifecycle status " \
              "counts, at-risk count, and — in full mode — grouped breakdowns and per-participant " \
              "progress. Returns no rating values."
  category :read
  approval :none

  parameter :cycle_id, String, required: true
  parameter :mode, String, required: false, allowed: %w[summary full]

  def policy_check
    authorize cycle, :cohort?
  end

  def perform
    result = ::Reporting::CycleCohort.new(
      cycle: cycle,
      scope_person_ids: scope_person_ids,
      mode: mode
    ).call

    serialize(result)
  end

  private

  def cycle
    @cycle ||= AssessmentCycle.find_by!(cycle_id: params[:cycle_id])
  end

  def mode
    params[:mode] == "full" ? :full : :summary
  end

  def policy
    @policy ||= AssessmentCyclePolicy.new(context, cycle)
  end

  # nil = whole cycle (admin/HR); otherwise the caller's org subtree.
  def scope_person_ids
    return nil if policy.cohort_full_access?

    context.person&.all_reports&.pluck(:id) || []
  end

  def serialize(result)
    {
      cycle: {
        id: result.cycle.cycle_id,
        name: result.cycle.name,
        planned_end_at: result.cycle.planned_end_at
      },
      total: result.total,
      funnel: funnel_payload(result.funnel),
      status_counts: result.status_counts,
      at_risk_count: result.at_risk_count,
      top_lagging_group: group_payload(result.top_lagging_group),
      groups: result.groups.transform_values { |list| list.map { |group| group_payload(group) } },
      participants: result.participants.map { |participant| participant_payload(participant) }
    }
  end

  def funnel_payload(funnel)
    {
      enrolled: funnel.enrolled,
      self_done: funnel.self_done, self_pct: funnel.self_pct,
      manager_done: funnel.manager_done, manager_pct: funnel.manager_pct,
      aligned: funnel.aligned, aligned_pct: funnel.aligned_pct
    }
  end

  def group_payload(group)
    return nil unless group

    {
      label: group.label,
      total: group.total,
      aligned_pct: group.funnel.aligned_pct,
      at_risk_count: group.at_risk_count
    }
  end

  def participant_payload(participant)
    {
      person_id: participant.person_id,
      name: participant.name,
      role: participant.role_name,
      level_ordinal: participant.level_ordinal,
      status: participant.status,
      self_done: participant.self_done,
      manager_done: participant.manager_done,
      aligned: participant.aligned,
      at_risk: participant.at_risk
    }
  end
end
