# frozen_string_literal: true

# Projection read model for framework collaborator assignments.
#
# Materialised from CollaboratorAdded / CollaboratorRoleChanged /
# CollaboratorRemoved events by {Frameworks::Projections::PublishedState}.
#
# A person can hold multiple roles on the same framework. Permissions
# are the union of all held roles (additive, never subtractive).
#
class FrameworkState::Collaborator < ApplicationRecord
  self.table_name = "framework_collaborators"

  acts_as_tenant :tenant
  belongs_to :tenant

  ROLES = %w[
    owner editor
    role_family_lead role_lead
    capability_category_lead capability_lead
    collaborator viewer
  ].freeze

  EDIT_ROLES = %w[owner editor role_family_lead role_lead capability_category_lead capability_lead].freeze
  PUBLISH_ROLES = %w[owner editor].freeze

  validates :framework_id, presence: true
  validates :person_id, presence: true
  validates :role, presence: true, inclusion: { in: ROLES }

  scope :for_framework, ->(framework_id) { where(framework_id: framework_id) }
  scope :for_person, ->(person_id) { where(person_id: person_id) }
  scope :with_edit_rights, -> { where(role: EDIT_ROLES) }
  scope :with_publish_rights, -> { where(role: PUBLISH_ROLES) }
end
