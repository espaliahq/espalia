# frozen_string_literal: true

class PagesController < ApplicationController
  # GET /
  def index
    tenants = ActsAsTenant.without_tenant { current_user.tenants.to_a }
    render Views::Pages::IndexView.new(
      user: current_user,
      current_tenant: ActsAsTenant.current_tenant,
      tenants: tenants
    )
  end
end
