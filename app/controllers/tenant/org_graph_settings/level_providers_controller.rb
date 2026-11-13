# frozen_string_literal: true

# Saves who supplies an empty structure level, from the settings screen's
# levels panel. A level that holds units changes hands through the handover.
class Tenant::OrgGraphSettings::LevelProvidersController < ApplicationController
  include OrgGraphSettingsRedirect

  # PATCH /tenant/org_graph/settings/level_providers/:level_id
  def update
    authorize :org_graph, :edit_structure?

    result = Operations::OrgGraph::SetLevelProvider.call(
      context: pundit_user, params: { level_id: params.expect(:level_id), provider: params.expect(:provider), field: params[:field].presence }.compact
    )
    back_with_notice notice_for(result)
  rescue Operations::Base::ParameterError => e
    back_with_refusal "#{OrgTaxonomyLevel.find_by(id: params[:level_id].to_s.downcase)&.name || 'The level'} did not change", e
  end

  private

  def notice_for(level)
    return "#{level[:name]} now comes from Espalia." if level[:provider] == OrgGraph::StructureAggregate::ESPALIA

    "#{level[:name]} is now read from the #{HrisConfig.provider_label(level[:provider])} field you chose."
  end
end
