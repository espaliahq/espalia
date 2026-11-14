# frozen_string_literal: true

# Synchronous handler: when a plan is deleted, destroys every key it holds,
# so what it wrote under them reads as removed and it can mint no new one.
#
# It runs in the transaction that appended `PlanDeleted`, after the append, so
# the event and the destroyed keys commit together, whichever path wrote the
# event. A repeat destroys nothing more.
#
# NEVER replayed on projection rebuild: it changes the key store, not a read
# model. It is subscribed, not registered in `Projections::Registry::REPLAYABLE`.
#
class TeamPlanning::SyncHandlers::DeletedPlanKeys
  # @return [Array<Class>]
  def self.handled_events
    [ TeamPlanning::Events::PlanDeleted ]
  end

  # @param event [TeamPlanning::Events::PlanDeleted]
  def call(event)
    ActsAsTenant.with_tenant(Tenant.find(event.metadata[:tenant_id])) do
      PlanKeyStore.new.destroy_plan(event.data[:plan_id])
    end
  end
end
