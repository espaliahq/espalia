# frozen_string_literal: true

# Resolves the viewer's per-framework suggestion-approval authority — the value
# object that gates every grid-side Approve / Reject affordance (the §12
# actionable pattern). Include in any controller whose response renders a
# component that can carry an approval kebab; expects `@framework` to be set.
module Frameworks::SuggestionAuthority
  extend ActiveSupport::Concern

  private

  # @return [Frameworks::SuggestionApprovalAuthority]
  def framework_suggestion_approval_authority
    Frameworks::SuggestionApprovalAuthority.for(
      framework_id: @framework.framework_id,
      person: current_person,
      tenant_admin: current_user&.global_admin? || current_tenant_user&.admin? || false
    )
  end
end
