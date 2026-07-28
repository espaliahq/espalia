# frozen_string_literal: true

# Cross-stream synchronous handler: mirrors a calibration session's
# rating-revisit request onto the calibrated person's PersonDevelopment
# stream, so the nudge surfaces in the rater's assessment activity feed
# where they work (docs/architecture/calibration-sessions.md → "Outcomes").
#
# IMPORTANT INVARIANTS
# ====================
#
# 1. **Same transaction as originator**: registered via
#    `event_store.subscribe`, so the PD mirror lands inline with the
#    session-stream publish. A failure rolls both back — session
#    provenance never points at a nudge the rater can't see.
#
# 2. **NEVER replayed on projection rebuild**: this handler dispatches a
#    PersonDevelopment command. Replaying it would duplicate the mirror
#    event on the person's stream. The registry guard at
#    `test/lib/projections/registry_test.rb` keeps it out of the rebuild
#    list at the source.
#
class AssessmentCycles::SyncHandlers::CalibrationRevisitSync
  # All event classes this handler subscribes to.
  #
  # @return [Array<Class>]
  def self.handled_events
    [ AssessmentCycles::Events::CalibrationRatingRevisitRequested ]
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
    data = event.data
    session = CalibrationSession.find_by(id: data[:session_id])
    return unless session

    PersonDevelopment::CommandHandler.new.request_rating_revisit(
      data[:person_id], session.framework_id,
      capability_stable_id: data[:capability_stable_id],
      level_ordinal: data[:level_ordinal],
      calibration_session_id: data[:session_id],
      rater_id: data[:rater_id],
      note: data[:note],
      session_name: session.name,
      requested_by_id: data[:requested_by_id]
    )
  end
end
