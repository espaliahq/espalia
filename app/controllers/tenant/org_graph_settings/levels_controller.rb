# frozen_string_literal: true

# Adds a unit type, or removes one no unit holds from today, from the settings
# screen's unit types panel.
class Tenant::OrgGraphSettings::LevelsController < ApplicationController
  include OrgGraphSettingsRedirect
  include OrgStructureAuthorization

  # POST /tenant/org_graph/settings/levels
  def create
    authorize_structure_of!(structure_unit)

    result = Operations::OrgGraph::AddLevel.call(context: pundit_user, params: { name: params[:name].to_s, **in_structure })
    top = result[:structure_unit_id] ? "directly under #{OrgUnit.find_by(id: result[:structure_unit_id])&.name}" : "at the top"
    back_with_notice "#{result[:name]} is a unit type now. It can sit under any other type, or #{top}, until you narrow that.", anchor:
  rescue Operations::Base::ParameterError => e
    back_with_refusal "The unit type could not be added", e, anchor:
  end

  # DELETE /tenant/org_graph/settings/levels/:id
  def destroy
    authorize_structure_of!(structure_unit)

    result = Operations::OrgGraph::RemoveLevel.call(context: pundit_user, params: { level_id: params[:id].to_s, **in_structure })
    back_with_notice "#{result[:name] || 'The unit type'} is no longer a unit type.", anchor:
  rescue Operations::Base::ParameterError => e
    back_with_refusal "The unit type could not be removed", e, anchor:
  end

  private

  def in_structure = params[:structure_unit_id].present? ? { structure_unit_id: params[:structure_unit_id].to_s } : {}

  def anchor = params[:structure_unit_id].presence && Views::Tenant::OrgGraph::Settings::LevelsPanel.anchor(params[:structure_unit_id])
end
