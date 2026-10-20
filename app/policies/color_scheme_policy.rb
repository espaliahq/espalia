# frozen_string_literal: true

# Authorization for a user's own colour scheme.
#
# Headless symbol policy: `authorize :color_scheme, :update?`. The choice is
# personal and cross-tenant, and the controller only ever writes
# `current_user`, so any signed-in user may change their own and nobody else's.
class ColorSchemePolicy < ApplicationPolicy
  # @return [Boolean]
  def update? = user.present?
end
