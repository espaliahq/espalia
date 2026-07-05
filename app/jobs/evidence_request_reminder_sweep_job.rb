# frozen_string_literal: true

# Hourly sweep (config/recurring.yml) that nudges requestees about pending
# feedback / evidence requests: after 7 quiet days, and/or 2 days before the
# optional due date — whichever threshold is crossed first. The timing policy
# lives on {EvidenceRequest} (`reminder_candidates` + `due_reminder_kind`);
# the once-per-kind guarantee lives in the PersonDevelopment aggregate, so a
# sweep that re-runs or races a response is rejected there rather than
# double-pinging anyone. Delivery then rides the normal event chain
# (EvidenceRequestReminderSent → async notifier → in-app / Slack).
#
# Events dispatched here carry `acting_via: "system"` provenance — there is no
# human actor; the job id correlates every reminder one run produced.
class EvidenceRequestReminderSweepJob < ApplicationJob
  queue_as :default

  # @return [void]
  def perform
    AuditMetadata.with(acting_via: :system, correlation_id: job_id) do
      Tenant.find_each do |tenant|
        ActsAsTenant.with_tenant(tenant) { sweep }
      rescue => e
        # One tenant's failure must not starve every tenant after it in the
        # run; the next hourly sweep catches whatever this one missed.
        Rails.logger.error("[EvidenceRequestReminderSweep] Tenant #{tenant.id} sweep failed: #{e.message}")
      end
    end
  end

  private

  def sweep
    handler = PersonDevelopment::CommandHandler.new
    EvidenceRequest.reminder_candidates.find_each do |request|
      kind = request.due_reminder_kind
      next if kind.nil?

      remind(handler, request, kind)
    end
  end

  def remind(handler, request, kind)
    AuditMetadata.wrap_event_store do
      handler.remind_evidence_request(request.person_id, request.framework_id, request.id, kind: kind)
    end
  rescue PersonDevelopment::Aggregate::CommandError => e
    # Lost a race (responded / already reminded) — the whole point of the
    # aggregate guard. Skip and keep sweeping.
    Rails.logger.info("[EvidenceRequestReminderSweep] Skipped #{request.id}: #{e.message}")
  end
end
