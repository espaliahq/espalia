# frozen_string_literal: true

# Event emitted when a collaborator is removed from a framework.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :framework_id UUID of the framework
#   @option data [String] :person_id UUID of the collaborator being removed
#   @option data [String] :collaborator_role the role being removed
#   @option data [String, nil] :scope_type nil (framework-wide), role_family, role,
#     capability_category, or capability
#   @option data [String, nil] :scope_id UUID of the scoped entity, or nil
#   @option data [String] :removed_by person_id of who removed the collaborator
#
class Frameworks::Events::CollaboratorRemoved < RubyEventStore::Event
end
