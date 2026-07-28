# frozen_string_literal: true

# Cross-stream synchronous handler: closes every not-yet-closed
# calibration session belonging to an assessment cycle when that cycle
# closes.
#
# Calibration sessions reference their cycle but own their streams
# (see docs/architecture/calibration-sessions.md), so the cycle's
# `CycleClosed` event can't close them transactionally from inside the
# cycle aggregate. This handler enumerates the cycle's open sessions
# via the read model and dispatches `close_session` (reason
# "cycle_closed") per session.
#
# IMPORTANT INVARIANTS
# ====================
#
# 1. **Same transaction as originator**: registered via
#    `event_store.subscribe` so each session close runs inline with the
#    cycle-close publish. A failure rolls back the close.
#
# 2. **NEVER replayed on projection rebuild**: this handler dispatches
#    commands. The session aggregate's close is a no-op when already
#    closed, so an accidental replay converges, but the registry guard
#    at `test/lib/projections/registry_test.rb` keeps it out of the
#    rebuild list at the source.
#
# 3. **Not-closed filter on the read model**: keeps the dispatched
#    command count predictable; the aggregate's no-op close is the
#    backstop, not the primary filter.
#
class AssessmentCycles::SyncHandlers::CalibrationSessionCloseSync
  # All event classes this handler subscribes to.
  #
  # @return [Array<Class>]
  def self.handled_events
    [ AssessmentCycles::Events::CycleClosed ]
  end

  # @param event [RubyEventStore::Event]
  def call(event)
    tenant = Tenant.find(event.metadata[:tenant_id])
    ActsAsTenant.with_tenant(tenant) do
      handle(event)
    end
  end

  private

  def handle(event)
    CalibrationSession
      .for_cycle(event.data[:cycle_id])
      .not_closed
      .pluck(:id)
      .each do |session_id|
        command_handler.close_session(session_id, reason: "cycle_closed")
      end
  end

  def command_handler
    @command_handler ||= AssessmentCycles::CalibrationCommandHandler.new
  end
end
