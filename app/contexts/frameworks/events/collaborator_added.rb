# frozen_string_literal: true

# Event emitted when a collaborator is added to a framework.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :framework_id UUID of the framework
#   @option data [String] :person_id UUID of the person being added
#   @option data [String] :collaborator_role one of: owner, editor, role_family_lead,
#     role_lead, capability_category_lead, capability_lead, collaborator, viewer
#   @option data [String, nil] :scope_type nil (framework-wide), role_family, role,
#     capability_category, or capability
#   @option data [String, nil] :scope_id UUID of the scoped entity, or nil
#   @option data [String] :added_by person_id of who added the collaborator
#
class Frameworks::Events::CollaboratorAdded < RubyEventStore::Event
end
