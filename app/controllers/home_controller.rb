# frozen_string_literal: true

# The Home dashboard — a composable, role-aware surface of actionable insights
# and next actions. Replaces the old root redirect to framework/assessments.
#
# {#show} renders the card grid (lazy frame per visible card instance); {#card}
# serves an individual card's content frame. Card composition lives in
# {Home::Registry}; see {Home::Card} for the framework.
class HomeController < ApplicationController
  # GET /
  def show
    authorize :home, :show?

    render Views::Home::DashboardView.new(
      card_instances: Home::Registry.instances_for(pundit_user),
      user: current_user,
      current_tenant: ActsAsTenant.current_tenant,
      tenants: current_user_tenants
    )
  end

  # GET /home/cards/:card(/:key)
  def card
    authorize :home, :card?

    card_class = Home::Registry.find(params[:card])
    raise ActiveRecord::RecordNotFound, "Unknown card: #{params[:card]}" unless card_class
    raise Pundit::NotAuthorizedError unless card_class.audience?(pundit_user)

    instance_key = params[:key].presence || "default"
    render Views::Home::CardFrame.new(
      dom_id: "home-card-#{card_class.key}-#{instance_key}",
      content: card_class.new(pundit_user).render_content(instance_key)
    ), layout: false
  end

  private

  def current_user_tenants
    ActsAsTenant.without_tenant { current_user.tenants.to_a }
  end
end
