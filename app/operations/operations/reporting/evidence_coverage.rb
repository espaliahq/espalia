# frozen_string_literal: true

# Aggregate feedback provision and evidence-request coverage for an assessment
# cycle, shared by the web report and MCP. Managers are restricted to their
# live org subtree; admins can view the whole cycle or choose their own subtree.
# Returns counts only — never feedback content or contributor identities.
class Operations::Reporting::EvidenceCoverage < Operations::Base
  description "Aggregate feedback and evidence-request coverage for an assessment cycle " \
              "across the caller's org subtree (admins see the whole cycle): feedback " \
              "provided by request or unsolicited, immutable manager/report/peer directionality, " \
              "withdrawn feedback, request statuses, fulfilment rate, participant coverage, " \
              "and optional manager/role/level groups."
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
      feedback_directionality: directionality_payload(metrics.directionality),
      requests_sent: metrics.requests_sent,
      requests_fulfilled: metrics.requests_fulfilled,
      requests_pending: metrics.requests_pending,
      requests_declined: metrics.requests_declined,
      requests_cancelled: metrics.requests_cancelled,
      request_fulfillment_pct: metrics.request_fulfillment_pct
    }
  end

  def directionality_payload(directionality)
    {
      interpersonal_total: directionality.interpersonal_total,
      manager_to_report: directionality.manager_to_report,
      manager_to_report_pct: directionality.percentage_for(:manager_to_report),
      peer_to_peer: directionality.peer_to_peer,
      peer_to_peer_pct: directionality.percentage_for(:peer_to_peer),
      report_to_manager: directionality.report_to_manager,
      report_to_manager_pct: directionality.percentage_for(:report_to_manager),
      legacy_peer_or_upward: directionality.legacy_peer_or_upward,
      legacy_peer_or_upward_pct: directionality.percentage_for(:legacy_peer_or_upward),
      self_provided: directionality.self_provided
    }
  end
end
