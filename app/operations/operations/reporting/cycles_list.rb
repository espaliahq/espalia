# frozen_string_literal: true

# The assessment cycles the caller may report on, open and closed — where an
# MCP client finds the `cycle_id` the other reporting tools take. Admins/HR
# see every cycle; a manager sees the cycles with someone from their subtree
# enrolled ({AssessmentCyclePolicy::Scope}), counted over that subtree only,
# exactly as `reporting_cycle_cohort` counts them.
class Operations::Reporting::CyclesList < Operations::Base
  CYCLE_ID_SCHEMA = { description: "An assessment cycle's id, from reporting_cycles_list." }.freeze
  UUID_FORMAT = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

  description "List the assessment cycles the caller can report on, newest first, with their " \
              "status, opened / planned end / closed dates, framework and version range, and " \
              "participant count. Admins see every cycle (scope: \"mine\" narrows to their own " \
              "org subtree); a manager sees the cycles with someone from their subtree enrolled, " \
              "and counts only that subtree. A listed id works with reporting_cycle_cohort, " \
              "reporting_capability_attainment and reporting_evidence_coverage; " \
              "reporting_feedback_export is for tenant admins only."
  category :read
  approval :none

  parameter :status, String, required: false, allowed: AssessmentCycle::STATUSES
  parameter :framework_id, String, required: false, allow_blank: false, schema: { format: "uuid" }
  parameter :scope, String, required: false, allowed: %w[mine all]

  def policy_check
    authorize AssessmentCycle, :report_index?
  end

  def perform
    if params[:framework_id].present? && !UUID_FORMAT.match?(params[:framework_id])
      raise ParameterError, "framework_id must be a framework's UUID, from frameworks_list"
    end

    cycles = subtree_only? ? policy_scope.subtree : policy_scope.resolve
    cycles = cycles.where(status: params[:status]) if params[:status].present?
    cycles = cycles.where(framework_id: params[:framework_id]) if params[:framework_id].present?
    cycles = cycles.order(opened_at: :desc, cycle_id: :desc).to_a

    counts = participant_counts(cycles)
    frameworks = framework_names(cycles)
    { cycles: cycles.map { |cycle| cycle_payload(cycle, counts, frameworks) } }
  end

  private

  def policy_scope
    @policy_scope ||= AssessmentCyclePolicy::Scope.new(context, AssessmentCycle)
  end

  # Non-admins always see their subtree; admins do when they ask for "mine".
  def subtree_only?
    !context.tenant_admin? || params[:scope] == "mine"
  end

  # @return [Hash{String => Integer}] cycle id => non-withdrawn participants in scope
  def participant_counts(cycles)
    enrollments = AssessmentCycleEnrollment.active.where(cycle_id: cycles.map(&:cycle_id))
    enrollments = enrollments.where(person_id: context.person&.all_reports&.select(:id)) if subtree_only?
    enrollments.group(:cycle_id).count
  end

  def framework_names(cycles)
    FrameworkState::Framework.where(framework_id: cycles.map(&:framework_id).uniq).pluck(:framework_id, :name).to_h
  end

  def cycle_payload(cycle, counts, frameworks)
    {
      id: cycle.cycle_id,
      name: cycle.name,
      cycle_type: cycle.cycle_type,
      status: cycle.status,
      framework: { id: cycle.framework_id, name: frameworks[cycle.framework_id] },
      framework_version: cycle.framework_version,
      latest_framework_version: cycle.latest_framework_version,
      opened_at: cycle.opened_at&.utc&.iso8601,
      planned_end_at: cycle.planned_end_at&.iso8601,
      closed_at: cycle.closed_at&.utc&.iso8601,
      participant_count: counts.fetch(cycle.cycle_id, 0)
    }
  end
end
