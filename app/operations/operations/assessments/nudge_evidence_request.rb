# frozen_string_literal: true

# Manually nudges the requestee about a still-open evidence request the
# caller made. Requester or tenant admin only; repeatable, but only once
# {EvidenceRequest::NUDGE_GAP} has passed since the last reminder of any kind
# (automatic reminders reset the clock too). The nudge rides the same
# EvidenceRequestReminderSent → notifier chain as automatic reminders, with
# the nudger attributed in the event payload and the request's history.
#
# Write — :mcp_client.
class Operations::Assessments::NudgeEvidenceRequest < Operations::Base
  description "Nudge the requestee about an open feedback / evidence request you made " \
              "(available once 2 days have passed since the last reminder)."
  category :write
  approval :mcp_client

  parameter :request_id, String, required: true

  def policy_check
    raise Pundit::NotAuthorizedError, "not linked to a person" if context.person.nil?

    authorize evidence_request, :nudge?, policy_class: EvidenceRequestPolicy
  end

  # @return [Hash] { request_id, status, last_reminded_at }
  def perform
    raise Operations::Base::ParameterError, "Request is no longer open" unless evidence_request.pending?
    unless evidence_request.can_nudge?
      raise Operations::Base::ParameterError,
        "A reminder went out recently — you can nudge again 2 days after the last one."
    end

    PersonDevelopment::CommandHandler.new.remind_evidence_request(
      evidence_request.person_id, evidence_request.framework_id, evidence_request.id,
      kind: "manual", nudged_by_id: context.person.id
    )
    reloaded = evidence_request.reload
    { request_id: reloaded.id, status: reloaded.status, last_reminded_at: reloaded.last_reminded_at&.iso8601 }
  rescue PersonDevelopment::Aggregate::CommandError => e
    raise Operations::Base::ParameterError, e.message
  end

  private

  def evidence_request
    @evidence_request ||= EvidenceRequest.find(params[:request_id])
  end
end
