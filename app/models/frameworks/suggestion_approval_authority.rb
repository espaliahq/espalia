# frozen_string_literal: true

# Precomputed, per-viewer answer to "can you approve a suggestion targeting
# entity type X?" for the framework activity feed.
#
# Built once per request from the viewer's collaborator roles (or tenant-admin
# status) so the actionable feed never instantiates a policy per entry. Entity
# type → review tier is delegated to {FrameworkSuggestionPolicy.review_tier} and
# tier → roles to {FrameworkState::Collaborator}'s role scopes, so there is one
# source of truth for both halves of the mapping.
class Frameworks::SuggestionApprovalAuthority
  # No collaborator roles and not a tenant admin — approves nothing.
  #
  # @return [Frameworks::SuggestionApprovalAuthority]
  def self.none
    new(tenant_admin: false, tier1: false, tier2: false, tier3: false)
  end

  # Resolve the viewer's approval authority on a framework.
  #
  # @param framework_id [String]
  # @param person [Person, nil] the viewer's domain person (nil → no collaborator roles)
  # @param tenant_admin [Boolean] whether the viewer is a tenant/global admin
  # @return [Frameworks::SuggestionApprovalAuthority]
  def self.for(framework_id:, person:, tenant_admin:)
    return new(tenant_admin: true, tier1: true, tier2: true, tier3: true) if tenant_admin
    return none unless person

    roles = FrameworkState::Collaborator.for_framework(framework_id).for_person(person.id)
    content_approve = roles.with_content_approve_rights.exists?
    new(
      tenant_admin: false,
      tier1: roles.with_edit_rights.exists?,
      tier2: content_approve,
      tier3: content_approve
    )
  end

  def initialize(tenant_admin:, tier1:, tier2:, tier3:)
    @tenant_admin = tenant_admin
    @tiers = { 1 => tier1, 2 => tier2, 3 => tier3 }
  end

  # @param entity_type [String] the suggestion's target entity type
  # @return [Boolean] whether the viewer may approve/reject a suggestion of that type
  def can_approve?(entity_type)
    return true if @tenant_admin

    @tiers.fetch(FrameworkSuggestionPolicy.review_tier(entity_type), false)
  end

  # Whether the viewer may resolve a clarification — expectation-tier (3)
  # authority regardless of anchor, mirroring
  # {FrameworkSuggestionPolicy#resolve?}: whoever could change the text can
  # declare the question settled. The single view-side gate for the
  # "Resolve…" affordance (feed entry + pane card), so it can't drift from
  # the controller's policy check.
  #
  # @return [Boolean]
  def can_resolve_clarifications?
    @tenant_admin || @tiers.fetch(3, false)
  end

  # @return [Boolean] whether the viewer can approve anything at all (cheap gate)
  def any?
    @tenant_admin || @tiers.value?(true)
  end
end
