# frozen_string_literal: true

# Sets how many days a fact Espalia holds about a person may go without a
# change or a confirmation before it is stale. Ninety until someone sets
# another.
#
# Approval is :in_app, as for the tenant's other settings. Changing it marks
# no fact stale or fresh by itself; the stale list reads it each time.
class Operations::OrgGraph::UpdateStalenessThreshold < Operations::Base
  description "Set how many days a fact Espalia holds about a person (a title, a manager, a membership) may " \
              "go without a change or a confirmation before it counts as stale. The default is " \
              "#{OrgGraphConfig::DEFAULT_STALENESS_DAYS}; at most #{OrgGraphConfig::MAX_STALENESS_DAYS}."
  category :write
  approval :in_app

  parameter :staleness_days, Integer, required: true

  # @raise [Pundit::NotAuthorizedError] unless the caller may change the Org Graph's structure
  def policy_check
    authorize :org_graph, :edit_structure?
  end

  # @return [Hash] tenant_id and the threshold as it now reads
  # @raise [ParameterError] for a threshold out of range
  def perform
    tenant = ActsAsTenant.current_tenant
    tenant.with_lock do
      config = tenant.org_graph_config.dup
      config.staleness_days = params[:staleness_days]
      raise ParameterError, config.errors.full_messages.to_sentence unless config.valid?

      tenant.update!(org_graph_config: config)
    end
    { tenant_id: tenant.id, staleness_days: tenant.org_graph_config.staleness_days }
  end
end
