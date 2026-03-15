# frozen_string_literal: true

# Event emitted when a role family is updated.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :framework_id UUID of the framework
#   @option data [String] :role_family_id UUID of the role family
#   @option data [String] :name updated name (optional)
#   @option data [String] :description updated description (optional)
#
class Frameworks::Events::RoleFamilyUpdated < RubyEventStore::Event
end
