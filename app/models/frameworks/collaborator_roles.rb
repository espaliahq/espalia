# frozen_string_literal: true

# One viewer's collaborator roles on one framework, loaded once and answered in
# memory.
#
# A person holds a handful of roles at most, and the union of them answers every
# question the explorer asks — can they suggest, edit structure, publish, manage
# collaborators, approve at a tier. Each of those used to be its own `EXISTS`
# query, and an edit-mode render asks four or five of them (the policy's own
# checks plus {Frameworks::SuggestionApprovalAuthority}), twice over on any
# request that computes a conditional-GET key before rendering.
#
# Roles are additive, never subtractive — see
# {FrameworkState::Collaborator} for the role → rights mapping this reads.
class Frameworks::CollaboratorRoles
  # @return [Frameworks::CollaboratorRoles] a viewer with no roles at all
  def self.none
    new([])
  end

  # @param framework_id [String]
  # @param person_id [String, nil] nil → no roles (a user with no Person)
  # @return [Frameworks::CollaboratorRoles]
  def self.load(framework_id:, person_id:)
    return none if person_id.blank?

    new(FrameworkState::Collaborator
          .for_framework(framework_id)
          .for_person(person_id)
          .pluck(:role))
  end

  # @param roles [Array<String>]
  def initialize(roles)
    @roles = roles.to_set
  end

  # @return [Boolean] holds any collaborator role, including `viewer`
  def any?
    @roles.any?
  end

  # @return [Boolean]
  def can_suggest?
    intersects?(FrameworkState::Collaborator::SUGGEST_ROLES)
  end

  # @return [Boolean]
  def can_edit?
    intersects?(FrameworkState::Collaborator::EDIT_ROLES)
  end

  # @return [Boolean]
  def can_publish?
    intersects?(FrameworkState::Collaborator::PUBLISH_ROLES)
  end

  # @return [Boolean]
  def can_approve_content?
    intersects?(FrameworkState::Collaborator::CONTENT_APPROVE_ROLES)
  end

  # @return [Boolean] owners curate a framework's collaborators
  def owner?
    @roles.include?("owner")
  end

  private

  def intersects?(roles)
    @roles.intersect?(roles.to_set)
  end
end
