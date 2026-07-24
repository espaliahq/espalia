# frozen_string_literal: true

# Aggregate feedback provision and evidence-request coverage for an assessment
# cycle, shared by the web report and MCP. Managers are restricted to their
# live org subtree; admins can view the whole cycle or choose their own subtree.
# Returns counts only — never feedback content or contributor identities.
class Operations::Reporting::EvidenceCoverage < Operations::Base
  description "Aggregate feedback and evidence-request coverage for an assessment cycle " \
              "across the caller's org subtree (admins see the whole cycle): feedback " \
              "provided by request or unsolicited, withdrawn feedback, request statuses, " \
              "fulfilment rate, participant coverage, and optional manager/role/level groups."
  category :read
  approval :none

  parameter :cycle_id, String, required: true
  parameter :mode, String, required: false, allowed: %w[summary full]
  parameter :scope, String, required: false, allowed: %w[mine all]

  def policy_check
    authorize cycle, :evidence_report?
  end

  # @return [Hash] aggregate cycle feedback coverage
  def perform
    result = ::Reporting::EvidenceCoverage.new(
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

  def scope_person_ids
    return context.person&.all_reports&.pluck(:id) || [] if scope_to_subtree?

    nil
  end

  def scope_to_subtree?
    !policy.cohort_full_access? || params[:scope] == "mine"
  end

  def serialize(result)
    {
      cycle: { id: result.cycle.cycle_id, name: result.cycle.name },
      metrics: metrics_payload(result.metrics),
      groups: result.groups.transform_values do |groups|
        groups.map { |group| group_payload(group) }
      end
    }
  end

  def group_payload(group)
    {
      key: group.key,
      label: group.label,
      metrics: metrics_payload(group.metrics)
    }
  end

  def metrics_payload(metrics)
    {
      participant_count: metrics.participant_count,
      participants_with_feedback: metrics.participants_with_feedback,
      participant_coverage_pct: metrics.participant_coverage_pct,
      feedback_provided: metrics.feedback_provided,
      provided_by_request: metrics.provided_by_request,
      provided_unsolicited: metrics.provided_unsolicited,
      feedback_withdrawn: metrics.feedback_withdrawn,
      requests_sent: metrics.requests_sent,
      requests_fulfilled: metrics.requests_fulfilled,
      requests_pending: metrics.requests_pending,
      requests_declined: metrics.requests_declined,
      requests_cancelled: metrics.requests_cancelled,
      request_fulfillment_pct: metrics.request_fulfillment_pct
    }
  end
end
