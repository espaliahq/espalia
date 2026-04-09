# frozen_string_literal: true

# Authorization for assessment cycle management.
#
# NOTE: V1 has no AssessmentCyclesController — cycles are created via the
# seed task and (temporarily) rails console. This policy exists for unit
# tests and in preparation for the admin UI; once that UI lands the policy
# will be wired into controller actions.
#
# All mutations require tenant admin (or global admin). Non-admins cannot
# define, enroll, unenroll, or close cycles.
#
class AssessmentCyclePolicy < ApplicationPolicy
  def index?
    tenant_admin?
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
end
