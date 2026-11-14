# frozen_string_literal: true

# Moves a level up or down one place, from the settings screen's levels panel.
# The form sends the whole new order, so a level added meanwhile refuses the
# move instead of being dropped.
class Tenant::OrgGraphSettings::LevelOrdersController < ApplicationController
  include OrgGraphSettingsRedirect

  # PATCH /tenant/org_graph/settings/level_order
  def update
    authorize :org_graph, :edit_taxonomy?

    Operations::OrgGraph::ReorderLevels.call(context: pundit_user, params: { level_ids: params.expect(level_ids: []) })
    back_with_notice "#{moved_name} moved #{direction}."
  rescue Operations::Base::ParameterError => e
    back_with_refusal "#{moved_name} did not move", e
  end

  private

  def direction = params[:direction] == "down" ? "down" : "up"

  def moved_name
    OrgTaxonomyLevel.find_by(id: params[:level_id].to_s.downcase)&.name || "The level"
  end
end
