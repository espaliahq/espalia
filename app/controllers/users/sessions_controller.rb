# frozen_string_literal: true

# Overrides Devise's SessionsController to render the sign-in page using Phlex.
class Users::SessionsController < Devise::SessionsController
  # GET /users/sign_in
  def new
    self.resource = resource_class.new
    render Views::Users::Sessions::NewView.new(
      resource: resource, flash: flash,
      google_sso: Rails.configuration.x.google_sso_available
    )
  end
end
