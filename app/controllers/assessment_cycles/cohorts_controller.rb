# frozen_string_literal: true

# Cohort progress roll-up for an assessment cycle — an aggregate, drill-downable
# view of how the cycle is progressing across an org subtree. Broader audience
# than the admin-only cycle management surface: any manager may view the slice
# of participants within their org subtree; admins/HR see the whole cycle.
class AssessmentCycles::CohortsController < ApplicationController
  before_action :set_cycle

  # GET /assessment_cycles/:id/cohort
  def show
    authorize @cycle, :cohort?

    result = Reporting::CycleCohort.new(
      cycle: @cycle,
      scope_person_ids: cohort_scope_ids,
      mode: :full
    ).call

    render Views::AssessmentCycles::Cohort::ShowView.new(
      result: result,
      pivot: pivot_param,
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

  # nil = whole cycle (admin/HR); otherwise the viewer's org subtree.
  def cohort_scope_ids
    return nil if policy(@cycle).cohort_full_access?

    current_person&.all_reports&.pluck(:id) || []
  end

  def pivot_param
    %w[manager role level].include?(params[:pivot]) ? params[:pivot] : "manager"
  end

  def current_user_tenants
    ActsAsTenant.without_tenant { current_user.tenants.to_a }
  end
end
