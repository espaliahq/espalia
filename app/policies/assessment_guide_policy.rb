# frozen_string_literal: true

# Authorizes the "How assessments work" guide. It explains the process and
# shows no one's data, so any member of the tenant may read it.
class AssessmentGuidePolicy < ApplicationPolicy
  # @return [Boolean]
  def show? = tenant_member? || tenant_admin?
end
