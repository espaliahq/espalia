# frozen_string_literal: true

# Aggregate feedback provision and evidence-request coverage for an assessment
# cycle, shared by the web report and MCP. Managers are restricted to their
# live org subtree; admins can view the whole cycle or choose their own subtree.
# An optional `month` narrows the counts to one calendar month of the cycle.
# Returns counts only — never feedback content or contributor identities.
class Operations::Reporting::EvidenceCoverage < Operations::Base
  description "Aggregate feedback and evidence-request coverage for an assessment cycle " \
              "across the caller's org subtree (admins see the whole cycle): feedback " \
              "provided by request or as proactive feedback, immutable manager/report/peer directionality, " \
              "withdrawn feedback, where it was given (by_origin: GrowthOS, or the system it arrived from), " \
              "request statuses, fulfilment rate, participant coverage, " \
              "and optional manager/role/level groups. Pass month (YYYY-MM) to narrow to feedback " \
              "recorded and requests sent in one calendar month of the cycle; the response lists " \
              "the months available."
  category :read
  approval :none

  parameter :cycle_id, String, required: true,
    schema: Operations::Reporting::CyclesList::CYCLE_ID_SCHEMA
  parameter :mode, String, required: false, allowed: %w[summary full]
  parameter :scope, String, required: false, allowed: %w[mine all]
  # `allow_blank: false` keeps the runtime in step with the advertised pattern
  # (which no empty string matches): omit the key for the whole cycle.
  parameter :month, String, required: false, allow_blank: false, schema: {
    pattern: ::Reporting::CycleMonth::JSON_SCHEMA_PATTERN,
    description: "Calendar month within the cycle, YYYY-MM. Omit for the whole cycle."
  }

  # Anyone the cycle's evidence report admits: managers with reports in the
  # cycle, tenant admins, and global admins (`AssessmentCyclePolicy#evidence_report?`).
  #
  # @raise [Pundit::NotAuthorizedError] when the caller may not view the report
  # @raise [ActiveRecord::RecordNotFound] when the cycle doesn't exist in the tenant
  def policy_check
    authorize cycle, :evidence_report?
  end

  # @return [Hash] aggregate cycle feedback coverage
  def perform
    month = resolve_month
    result = ::Reporting::EvidenceCoverage.new(
      cycle: cycle,
      scope_person_ids: scope_person_ids,
      mode: mode,
      period: month&.range
    ).call

    serialize(result, month)
  end

  private

  def cycle
    @cycle ||= AssessmentCycle.find_by!(cycle_id: params[:cycle_id])
  end

  def mode
    params[:mode] == "full" ? :full : :summary
  end

  def available_months
    @available_months ||= ::Reporting::CycleMonth.available_for(cycle)
  end

  # The requested month, or nil for the whole cycle. A malformed key or a
  # month the cycle never spanned is the caller's mistake, so it surfaces as
  # a ParameterError (-32602 over MCP) rather than an empty report.
  def resolve_month
    key = params[:month]
    return nil if key.nil?

    unless ::Reporting::CycleMonth.valid_key?(key)
      raise ParameterError, "month must be formatted YYYY-MM, got #{key.inspect}"
    end

    ::Reporting::CycleMonth.find_in(cycle, key, months: available_months) ||
      raise(ParameterError,
            "month #{key} is outside the cycle's lifespan " \
            "(#{available_months.last.key} to #{available_months.first.key})")
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

  def serialize(result, month)
    {
      cycle: { id: result.cycle.cycle_id, name: result.cycle.name },
      period: period_payload(month),
      available_months: available_months.map { |candidate| { month: candidate.key, label: candidate.label } },
      metrics: metrics_payload(result.metrics),
      groups: result.groups.transform_values do |groups|
        groups.map { |group| group_payload(group) }
      end
    }
  end

  # @return [Hash, nil] the month the counts were narrowed to; nil for the whole cycle
  def period_payload(month)
    return nil unless month

    {
      month: month.key,
      label: month.label,
      starts_at: month.range.begin.iso8601,
      ends_at: month.range.end.iso8601
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
      by_origin: metrics.by_origin,
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
