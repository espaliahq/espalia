# frozen_string_literal: true

# Authorizes the Home dashboard. Any authenticated user may reach Home and its
# card endpoints; each card enforces its own audience scoping (see
# {Home::Card}) and any resource it surfaces enforces that resource's policy.
class HomePolicy < ApplicationPolicy
  def show? = user.present?
  def card? = user.present?
end
