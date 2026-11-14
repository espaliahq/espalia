# frozen_string_literal: true

# Saves who supplies one kind of fact, from the settings screen's sources panel.
class Tenant::OrgGraphSettings::FactProvidersController < ApplicationController
  include OrgGraphSettingsRedirect
  include Views::Tenant::OrgGraph::Settings::FactLabels

  PARTS = OrgGraph::StructureAggregate::MAPPABLE_FIELDS.values.flatten.freeze

  # PATCH /tenant/org_graph/settings/fact_providers/:fact
  def update
    authorize :org_graph, :edit_structure?

    result = Operations::OrgGraph::SetFactProvider.call(context: pundit_user, params: fact_params)
    source = provider_label(result[:provider])
    source = "the #{source} field you chose" if fact_params[:fields]
    back_with_notice "#{fact_label(result[:fact])} now comes from #{source}."
  rescue Operations::Base::ParameterError => e
    back_with_refusal "#{fact_label(params[:fact])} did not change", e
  end

  private

  def fact_params
    @fact_params ||= fact_params!
  end

  def fact_params!
    fields = params.fetch(:fields, {}).permit(*PARTS).to_h.presence
    { fact: params.expect(:fact), provider: params.expect(:provider), fields: }.compact
  end

  def provider_label(provider)
    provider == OrgGraph::StructureAggregate::ESPALIA ? "Espalia" : HrisConfig.provider_label(provider)
  end
end
