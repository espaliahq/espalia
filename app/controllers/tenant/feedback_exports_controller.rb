# frozen_string_literal: true

# Tenant-admin download of a cycle's feedback for monthly reporting (#458).
#
# `new` picks the cycle and month; `index.csv` streams the file. Both
# authorize against `TenantPolicy#export_feedback?` here and again inside
# {Operations::Reporting::FeedbackExport}, which the MCP tool shares.
class Tenant::FeedbackExportsController < ApplicationController
  # GET /tenant/feedback_exports/new
  def new
    authorize ActsAsTenant.current_tenant, :export_feedback?, policy_class: TenantPolicy

    cycles = AssessmentCycle.order(opened_at: :desc).to_a
    cycle = cycles.find { |candidate| candidate.cycle_id == params[:cycle_id] } || cycles.first

    render Views::Tenant::FeedbackExports::NewView.new(
      cycles: cycles,
      cycle: cycle,
      months: cycle ? Reporting::CycleMonth.available_for(cycle) : [],
      user: current_user,
      current_tenant: ActsAsTenant.current_tenant,
      tenants: tenants_for_user
    )
  end

  # GET /tenant/feedback_exports.csv
  def index
    authorize ActsAsTenant.current_tenant, :export_feedback?, policy_class: TenantPolicy

    respond_to do |format|
      format.csv { send_export }
      format.html { redirect_to new_tenant_feedback_export_path(cycle_id: params[:cycle_id]) }
    end
  end

  private

  def send_export
    export = Operations::Reporting::FeedbackExport.call(context: pundit_user, params: export_params)
    csv = Reporting::FeedbackExportCsv.new(export)
    send_data csv.to_s, type: "text/csv; charset=utf-8", filename: csv.filename, disposition: "attachment"
  rescue Operations::Base::ParameterError => e
    back_to_picker("Feedback could not be exported: #{e.message}")
  rescue ActiveRecord::RecordNotFound
    back_to_picker("Feedback could not be exported: that cycle doesn't exist.")
  end

  def back_to_picker(alert)
    redirect_to new_tenant_feedback_export_path(cycle_id: params[:cycle_id]), alert: alert, status: :see_other
  end

  # The month select's "Whole cycle" option submits a blank month, which the
  # Operation (rightly) rejects as a value — it means "no month" here.
  def export_params
    {
      cycle_id: params.expect(:cycle_id),
      month: params[:month].presence,
      include_withdrawn: params[:include_withdrawn].presence
    }.compact
  end

  # @return [Array<Tenant>]
  def tenants_for_user
    ActsAsTenant.without_tenant { current_user.tenants.to_a }
  end
end
