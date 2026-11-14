# frozen_string_literal: true

# Adds a level at the bottom of the taxonomy, or removes one no unit has ever
# held, from the settings screen's levels panel.
class Tenant::OrgGraphSettings::LevelsController < ApplicationController
  include OrgGraphSettingsRedirect

  # POST /tenant/org_graph/settings/levels
  def create
    authorize :org_graph, :edit_taxonomy?

    result = Operations::OrgGraph::AddLevel.call(context: pundit_user, params: { name: params[:name].to_s })
    back_with_notice "#{result[:name]} is now the bottom level. Move it up if it belongs higher."
  rescue Operations::Base::ParameterError => e
    back_with_refusal "The level could not be added", e
  end

  # DELETE /tenant/org_graph/settings/levels/:id
  def destroy
    authorize :org_graph, :edit_taxonomy?

    result = Operations::OrgGraph::RemoveLevel.call(context: pundit_user, params: { level_id: params[:id].to_s })
    back_with_notice "#{result[:name]} is no longer a level."
  rescue Operations::Base::ParameterError => e
    back_with_refusal "The level could not be removed", e
  end
end
