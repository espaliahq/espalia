# frozen_string_literal: true

# Authorization for assessment cycle management.
#
# All mutations require tenant admin (or global admin). Non-admins cannot
# define, edit, enroll, unenroll, or close cycles. `update?` is the single
# predicate for in-place edits to cycle attributes (name, type, planned end).
#
# The cohort progress view is broader: any manager with a participant anywhere
# in their org subtree may view it (scoped to that subtree), and admins/HR see
# the whole cycle. See `cohort?` / `cohort_full_access?`.
#
class AssessmentCyclePolicy < ApplicationPolicy
  def index?
    tenant_admin?
  end

  # Whether the viewer may see the cohort progress roll-up for this cycle.
  # Admins/HR always; otherwise any manager with at least one participant
  # somewhere below them in the org chart.
  def cohort?
    return true if cohort_full_access?
    return false unless person

    AssessmentCycleEnrollment
      .active
      .where(cycle_id: record.cycle_id, person_id: person.all_reports.select(:id))
      .exists?
  end

  # Whether the viewer sees the whole cycle (vs. only their own subtree).
  # Tenant admins / global admins act as HR for v1.
  def cohort_full_access?
    tenant_admin?
  end

  # Whether the viewer may see the capability attainment report for this
  # cycle. Same audience as the cohort roll-up.
  def attainment?
    cohort?
  end

  # Whether the viewer sees attainment aggregates without the small-cohort
  # suppression floor.
  #
  # The invariant suppression enforces: never show an aggregate derived from
  # data the viewer cannot open at the individual level. Since
  # AssessmentPolicy#show? grants the entire live manager chain full view of
  # each report's assessment, a manager's attainment scope (Person#all_reports,
  # the same live chart walk) is exactly the set whose individual assessments
  # they can already open — and tenant/global admins (whole-cycle scope) hold
  # AssessmentPolicy#show? on every assessment too — so the aggregate discloses
  # nothing new and every attainment viewer is currently unsuppressed. The suppression machinery in
  # Reporting::CapabilityAttainment stays for future audiences whose
  # individual-level visibility does NOT cover their aggregate scope (e.g.
  # org-wide transparency for members, department-scoped HR viewers) — such an
  # audience must return false here.
  def attainment_unsuppressed?
    attainment?
  end

  def show?
    tenant_admin? || tenant_member?
  end

  def define?
    tenant_admin?
  end

  def enroll?
    tenant_admin?
  end

  def unenroll?
    tenant_admin?
  end

  def close?
    tenant_admin?
  end

  def update?
    tenant_admin?
  end
end
