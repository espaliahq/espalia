# frozen_string_literal: true

# Capability attainment report for an assessment cycle — per role and role
# family, the share of people at or above their assessed level on each bound
# capability, with a category-gate roll-up. Same audience as the cohort view
# (managers see their subtree; admins/HR the whole cycle). Small-cohort
# suppression applies only to viewers who cannot open their scope's individual
# assessments — see AssessmentCyclePolicy#attainment_unsuppressed? (currently
# every attainment viewer qualifies as unsuppressed).
class AssessmentCycles::AttainmentsController < ApplicationController
  # URL param → PersonDevelopment::Scoring perspective.
  PERSPECTIVES = {
    "effective" => :effective,
    "self" => :self_only,
    "manager" => :manager_only,
    "aligned" => :aligned_only
  }.freeze

  before_action :set_cycle

  # GET /assessment_cycles/:id/attainment
  def show
    authorize @cycle, :attainment?

    result = Reporting::CapabilityAttainment.new(
      cycle: @cycle,
      scope_person_ids: attainment_scope_ids,
      perspective: PERSPECTIVES.fetch(perspective_param),
      suppress_small_groups: !policy(@cycle).attainment_unsuppressed?
    ).call

    render Views::AssessmentCycles::Attainment::ShowView.new(
      result: result,
      perspective: perspective_param,
      by: by_param,
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

  # nil = whole cycle; otherwise the viewer's org subtree. Non-admins are
  # always scoped to their subtree; admins/HR see the whole cycle by default
  # but can opt into their own subtree via `?scope=mine`.
  def attainment_scope_ids
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

  def perspective_param
    PERSPECTIVES.key?(params[:perspective]) ? params[:perspective] : "effective"
  end

  def by_param
    params[:by] == "family" ? "family" : "role"
  end

  def current_user_tenants
    ActsAsTenant.without_tenant { current_user.tenants.to_a }
  end
end
