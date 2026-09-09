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
      tenant_admin: current_user&.global_admin? || current_tenant_user&.admin? || false,
      collaborator_roles: framework_collaborator_roles
    )
  end

  # The viewer's collaborator roles on `@framework`, loaded once per request and
  # shared with everything that asks — the authority above, and (via Pundit's
  # per-record policy cache) the policy's own `edit?` / `edit_structure?` /
  # `publish?`. Each of those was a separate `EXISTS` for rows a person holds a
  # handful of (#383).
  #
  # @return [Frameworks::CollaboratorRoles]
  def framework_collaborator_roles
    @framework_collaborator_roles ||= Frameworks::CollaboratorRoles.load(
      framework_id: @framework.framework_id, person_id: current_person&.id
    )
  end
end
