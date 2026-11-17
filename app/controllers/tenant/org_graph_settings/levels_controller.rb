# frozen_string_literal: true

# Adds a unit type, or removes one no unit has ever been, from the settings
# screen's unit types panel.
class Tenant::OrgGraphSettings::LevelsController < ApplicationController
  include OrgGraphSettingsRedirect

  # POST /tenant/org_graph/settings/levels
  def create
    authorize :org_graph, :edit_taxonomy?

    result = Operations::OrgGraph::AddLevel.call(context: pundit_user, params: { name: params[:name].to_s })
    back_with_notice "#{result[:name]} is a unit type now. It can sit under any other type, or at the top, until you narrow that."
  rescue Operations::Base::ParameterError => e
    back_with_refusal "The unit type could not be added", e
  end

  # DELETE /tenant/org_graph/settings/levels/:id
  def destroy
    authorize :org_graph, :edit_taxonomy?

    result = Operations::OrgGraph::RemoveLevel.call(context: pundit_user, params: { level_id: params[:id].to_s })
    back_with_notice "#{result[:name] || 'The unit type'} is no longer a unit type."
  rescue Operations::Base::ParameterError => e
    back_with_refusal "The unit type could not be removed", e
  end
end
