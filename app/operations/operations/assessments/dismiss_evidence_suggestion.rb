# frozen_string_literal: true

# Turns down a placement suggestion, with an optional reason. A dismissed
# cell is never suggested for that item again. Dismissals are not activity
# entries: nothing about the person's evidence changed.
#
# Write — :mcp_client approval; authorised by {EvidencePolicy#add_link?},
# the same people who could have accepted it.
class Operations::Assessments::DismissEvidenceSuggestion < Operations::Base
  include Operations::Assessments::EvidenceSuggestion

  description "Dismiss a placement suggestion for a piece of feedback / evidence, optionally saying why. " \
              "The same capability × level is not suggested for that item again."
  category :write
  approval :mcp_client

  parameter :suggestion_id, String, required: true
  parameter :reason, String

  def policy_check
    raise Pundit::NotAuthorizedError, "not linked to a person" if context.person.nil?

    authorize evidence_item, :add_link?, policy_class: EvidencePolicy
  end

  # @return [Hash] the dismissed suggestion
  def perform
    ensure_pending!
    suggestion.decide!(status: "dismissed", by: context.person, reason: params[:reason])
    suggestion_payload(suggestion, capability_names([ suggestion ]))
  end
end
