# frozen_string_literal: true

# Feedback and evidence-request coverage for an assessment cycle. Managers see
# their live org subtree; admins/HR see the whole cycle and may narrow to their
# own subtree, and anyone can narrow the report to one month of the cycle. The
# shared Operation also backs the MCP tool surface.
class AssessmentCycles::EvidenceReportsController < ApplicationController
  before_action :set_cycle

  # GET /assessment_cycles/:id/evidence
  def show
    authorize @cycle, :evidence_report?

    report = Operations::Reporting::EvidenceCoverage.call(
      context: pundit_user,
      params: {
        cycle_id: @cycle.cycle_id,
        mode: "full",
        scope: scope_param,
        month: month_param
      }
    )

    render Views::AssessmentCycles::EvidenceReport::ShowView.new(
      cycle: @cycle,
      report: report,
      group_by: group_param,
      scope: scope_param,
      can_scope_to_self: can_scope_to_self?,
      can_export_feedback: policy(ActsAsTenant.current_tenant).export_feedback?,
      user: current_user,
      current_tenant: ActsAsTenant.current_tenant,
      tenants: current_user_tenants
    )
  end

  private

  def set_cycle
    @cycle = AssessmentCycle.find(params.expect(:id))
  rescue ActiveRecord::RecordNotFound
    redirect_to root_path, alert: "Cycle not found."
  end

  def group_param
    %w[manager role level].include?(params[:group]) ? params[:group] : "manager"
  end

  def scope_param
    params[:scope] == "mine" ? "mine" : "all"
  end

  # A month the cycle actually spans, or nil for the whole cycle. Anything
  # else (a typo, a month before the cycle opened) falls back to the whole
  # cycle like the other filter params — but says so, since the URL still
  # names the month a shared link asked for.
  def month_param
    return @month_param if defined?(@month_param)

    @month_param = Reporting::CycleMonth.find_in(@cycle, params[:month])&.key
    if params[:month].present? && @month_param.nil?
      flash.now[:alert] = "#{params[:month]} isn't a month of this cycle, so the whole cycle is shown."
    end
    @month_param
  end

  def can_scope_to_self?
    policy(@cycle).cohort_full_access? && current_person.present? && current_person.all_reports.exists?
  end

  def current_user_tenants
    ActsAsTenant.without_tenant { current_user.tenants.to_a }
  end
end
