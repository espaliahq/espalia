# frozen_string_literal: true

# Cross-stream synchronous handler: propagates AssessmentCycle enrollment
# events to PersonDevelopment streams.
#
# When a person is enrolled into (or unenrolled from) a cycle, this handler
# dispatches a PersonDevelopment command which emits a corresponding
# `JoinedAssessmentCycle` / `LeftAssessmentCycle` event on the person's
# PersonDev stream. This keeps the PersonDev stream self-contained — replaying
# it tells the full story of when the person was in which cycle.
#
# IMPORTANT INVARIANTS
# ====================
#
# 1. **Same transaction as originator**: registered via `event_store.subscribe`
#    so the PersonDev command dispatch runs inline with the cycle-event publish.
#    Handler failure rolls back the originating cycle command — an enrollment
#    that can't propagate to the person stream must be rejected cleanly.
#
# 2. **NEVER replayed on projection rebuild**: this handler dispatches commands,
#    not just read-model writes. Running it twice would raise "already in a cycle"
#    from the PersonDev aggregate. Register strictly as a subscription, NOT as a
#    projection. Do not add it to any rebuild list or replay pathway.
#
# 3. **Stateless**: cycle events are self-describing (carry framework_id +
#    framework_version). The handler never reads a cycle read model.
#
class AssessmentCycles::SyncHandlers::PersonEnrollmentSync
  # All event classes this handler subscribes to.
  #
  # @return [Array<Class>]
  def self.handled_events
    [
      AssessmentCycles::Events::PersonEnrolled,
      AssessmentCycles::Events::PersonUnenrolled,
      AssessmentCycles::Events::CycleClosed
    ]
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
    case event
    when AssessmentCycles::Events::PersonEnrolled then handle_person_enrolled(event)
    when AssessmentCycles::Events::PersonUnenrolled then handle_person_unenrolled(event)
    when AssessmentCycles::Events::CycleClosed then handle_cycle_closed(event)
    end
  end

  def handle_person_enrolled(event)
    command_handler.join_cycle(
      event.data[:person_id],
      event.data[:framework_id],
      event.data[:cycle_id],
      event.data[:framework_version]
    )
  end

  def handle_person_unenrolled(event)
    command_handler.leave_cycle(
      event.data[:person_id],
      event.data[:framework_id],
      event.data[:cycle_id],
      event.data[:reason]
    )
  end

  def handle_cycle_closed(event)
    Array(event.data[:enrolled_person_ids]).each do |person_id|
      command_handler.leave_cycle(
        person_id,
        event.data[:framework_id],
        event.data[:cycle_id],
        "cycle_closed"
      )
    end
  end

  def command_handler
    @command_handler ||= PersonDevelopment::CommandHandler.new
  end
end
