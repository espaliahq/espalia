# frozen_string_literal: true

# Feedback and evidence-request coverage for an assessment cycle. Managers see
# their live org subtree; admins/HR see the whole cycle and may narrow to their
# own subtree. The shared Operation also backs the MCP tool surface.
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
        scope: scope_param
      }
    )

    render Views::AssessmentCycles::EvidenceReport::ShowView.new(
      cycle: @cycle,
      report: report,
      group_by: group_param,
      scope: scope_param,
      can_scope_to_self: can_scope_to_self?,
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

  def can_scope_to_self?
    policy(@cycle).cohort_full_access? && current_person.present? && current_person.all_reports.exists?
  end

  def current_user_tenants
    ActsAsTenant.without_tenant { current_user.tenants.to_a }
  end
end
