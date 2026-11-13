# frozen_string_literal: true

# Synchronous handler: when a person leaves, ends each of their open
# memberships on the leaving date, as the system, writing back to the
# person's own stream. A returner comes back with none, and no position is
# opened in their place.
#
# The memberships come from the person's stream, not `org_memberships`, so
# the ends never wait on a projection. A membership that changed after a
# backdated leaving ends on the day it changed. A second `PersonLeft` that
# corrects the date finds nothing open, so memberships keep the date they
# ended on.
#
# RES stamps each end with the leaving as its causation_id, and the
# leaving's correlation id carries through. The repository holds both writes
# in one transaction.
#
# NEVER replayed on projection rebuild: it dispatches person commands. It is
# subscribed, not registered in `Projections::Registry::REPLAYABLE`.
#
class OrgGraph::SyncHandlers::LeaverMemberships
  # @return [Array<Class>]
  def self.handled_events
    [ OrgGraph::Events::PersonLeft ]
  end

  # @param event [OrgGraph::Events::PersonLeft]
  def call(event)
    data = event.data
    ActsAsTenant.with_tenant(Tenant.find(event.metadata[:tenant_id])) do
      OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
                              .end_memberships(data[:person_id], effective_on: data[:effective_on],
                                                                 **data.slice(:plan_id, :plan_change_id))
    end
  end
end
