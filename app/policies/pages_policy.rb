# frozen_string_literal: true

# Authorizes access to the root router action. Any authenticated user may
# reach `/`; the action only redirects to a destination controller, which
# enforces its own authorization.
#
class PagesPolicy < ApplicationPolicy
  def index? = user.present?
end
