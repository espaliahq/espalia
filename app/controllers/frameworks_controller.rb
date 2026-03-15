# frozen_string_literal: true

class FrameworksController < ApplicationController
  before_action :set_framework, only: [ :show ]

  # GET /frameworks
  def index
    @frameworks = FrameworkState::Framework.all
    tenants = ActsAsTenant.without_tenant { current_user.tenants.to_a }

    render Views::Frameworks::IndexView.new(
      frameworks: @frameworks,
      user: current_user,
      current_tenant: ActsAsTenant.current_tenant,
      tenants: tenants
    )
  end

  # GET /frameworks/:id
  def show
    tenants = ActsAsTenant.without_tenant { current_user.tenants.to_a }

    render Views::Frameworks::ShowView.new(
      framework: @framework,
      role_families: @framework.role_families
        .includes(roles: :levels)
        .order(:name),
      categories: @framework.capability_categories
        .includes(capabilities: [ :bindings, { expectations: :illustrations } ])
        .order(:ordinal),
      user: current_user,
      current_tenant: ActsAsTenant.current_tenant,
      tenants: tenants
    )
  end

  private

  def set_framework
    @framework = FrameworkState::Framework.find_by!(framework_id: params.expect(:id))
  rescue ActiveRecord::RecordNotFound
    redirect_to frameworks_path
  end
end
