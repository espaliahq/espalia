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

    # Which participant names link to their assessment: only those the viewer
    # may open (AssessmentPolicy#show? — admin / own / subtree / delegate).
    viewable_assignments = Assessments::ViewableAssessments.new(
      viewer: pundit_user,
      framework_id: @cycle.framework_id,
      person_ids: result.participants.map(&:person_id)
    ).call

    render Views::AssessmentCycles::Cohort::ShowView.new(
      result: result,
      pivot: pivot_param,
      scope: scope_param,
      can_scope_to_self: can_scope_to_self?,
      viewable_assignments: viewable_assignments,
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

  # nil = whole cycle; otherwise the viewer's org subtree. Non-admins are
  # always scoped to their subtree; admins/HR see the whole cycle by default
  # but can opt into their own subtree via `?scope=mine`.
  def cohort_scope_ids
    return nil unless scope_to_subtree?

    current_person&.all_reports&.pluck(:id) || []
  end

  def scope_to_subtree?
    !policy(@cycle).cohort_full_access? || scope_param == "mine"
  end

  def scope_param
    params[:scope] == "mine" ? "mine" : "all"
  end

  # Whether to offer the "My org / Whole cycle" toggle: only for a full-access
  # viewer (admin/HR) who is also a manager with reports to scope to.
  def can_scope_to_self?
    policy(@cycle).cohort_full_access? && current_person.present? && current_person.all_reports.exists?
  end

  def pivot_param
    %w[manager role level].include?(params[:pivot]) ? params[:pivot] : "manager"
  end

  def current_user_tenants
    ActsAsTenant.without_tenant { current_user.tenants.to_a }
  end
end
