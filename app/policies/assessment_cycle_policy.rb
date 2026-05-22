# frozen_string_literal: true

# Authorization for assessment cycle management.
#
# All mutations require tenant admin (or global admin). Non-admins cannot
# define, edit, enroll, unenroll, or close cycles. `update?` is the single
# predicate for in-place edits to cycle attributes (name, type, planned end).
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

  def update?
    tenant_admin?
  end
end
