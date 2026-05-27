# frozen_string_literal: true

# Cross-stream synchronous handler: propagates a framework version
# publish onto every OPEN AssessmentCycle scoped to that framework so
# each cycle records the upper bound of the version range it was open
# across.
#
# When `Frameworks::Events::FrameworkVersionPublished` lands, this
# handler enumerates open cycles for the framework and dispatches a
# `roll_framework_version` command per cycle. The AssessmentCycle
# aggregate records a `FrameworkVersionRolled` event on each cycle's
# stream, the projection advances the `latest_framework_version`
# column, and the views render the range (`v1–v2`) instead of just the
# define-time version.
#
# Closed cycles are intentionally not rolled — the range freezes at
# close time so historical reports reflect what the cycle actually
# assessed against.
#
# IMPORTANT INVARIANTS
# ====================
#
# 1. **Same transaction as originator**: registered via
#    `event_store.subscribe` so each cycle command runs inline with
#    the publish. A failure rolls back the publish.
#
# 2. **NEVER replayed on projection rebuild**: this handler dispatches
#    commands, not just read-model writes. Register as a subscription,
#    not a projection. The cycle aggregate's idempotency check
#    (`@latest_framework_version >= new_version`) makes an accidental
#    replay a no-op, but the registry guard at
#    `test/lib/projections/registry_test.rb` keeps it out of the
#    rebuild list at the source.
#
# 3. **Open-cycle filter**: closed cycles are skipped via the read
#    model query rather than relying on the aggregate to no-op them.
#    Cheaper and keeps the dispatched-command count predictable.
#
class AssessmentCycles::SyncHandlers::FrameworkVersionRollSync
  # All event classes this handler subscribes to.
  #
  # @return [Array<Class>]
  def self.handled_events
    [ Frameworks::Events::FrameworkVersionPublished ]
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
    framework_id = event.data[:framework_id]
    new_version  = event.data[:version]

    AssessmentCycle
      .where(framework_id: framework_id, status: "open")
      .pluck(:cycle_id)
      .each do |cycle_id|
        command_handler.roll_framework_version(cycle_id, new_version)
      end
  end

  def command_handler
    @command_handler ||= AssessmentCycles::CommandHandler.new
  end
end
