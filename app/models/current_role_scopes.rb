# frozen_string_literal: true

# The role scopes reused inside {Assessments::RoleScope.reusing}. A
# CurrentAttributes, so Rails resets it after every request and job even if
# the block's own cleanup never runs.
class CurrentRoleScopes < ActiveSupport::CurrentAttributes
  # @return [Hash{Array(String, String) => Assessments::RoleScope}, nil]
  #   keyed by [role_id, framework_id]; nil outside a reusing block
  attribute :memo
end
