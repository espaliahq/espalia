# frozen_string_literal: true

# Event-sourced aggregate for one person in the Org Graph.
#
# One RES stream per person: tenant-{tenant_id}/Person-{person_id}. It holds
# operational facts only, keyed by person id. Identifiers (name, email,
# external id) live on the `people` row and never in an event.
#
class OrgGraph::PersonAggregate
  include AggregateRoot
end
