# frozen_string_literal: true

# Saves the settings screen's staleness threshold.
class Tenant::OrgGraphSettings::FreshnessController < ApplicationController
  include OrgGraphSettingsRedirect

  # PATCH /tenant/org_graph/settings/freshness
  def update
    authorize :org_graph, :edit_structure?

    result = Operations::OrgGraph::UpdateStalenessThreshold.call(
      context: pundit_user, params: { staleness_days: params.expect(:staleness_days).to_i }
    )
    back_with_notice "A fact now counts as stale after #{result[:staleness_days]} days."
  rescue Operations::Base::ParameterError => e
    back_with_refusal "The threshold could not be saved", e
  end
end
