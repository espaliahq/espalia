# frozen_string_literal: true

# Event emitted when a collaborator's role is changed on a framework.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :framework_id UUID of the framework
#   @option data [String] :person_id UUID of the collaborator
#   @option data [String] :old_role previous collaborator role
#   @option data [String] :new_role updated collaborator role
#   @option data [String, nil] :scope_type nil (framework-wide), role_family, role,
#     capability_category, or capability
#   @option data [String, nil] :scope_id UUID of the scoped entity, or nil
#   @option data [String] :changed_by person_id of who made the change
#
class Frameworks::Events::CollaboratorRoleChanged < RubyEventStore::Event
end
