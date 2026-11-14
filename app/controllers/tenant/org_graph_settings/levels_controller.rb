# frozen_string_literal: true

# Adds a level at the bottom of the taxonomy, from the settings screen's
# levels panel.
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
end
