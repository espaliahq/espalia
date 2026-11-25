# frozen_string_literal: true

# Turns down a placement suggestion, with an optional reason. A dismissed
# cell is never suggested for that item again. The dismissal shows in the
# assessment's activity and the link's thread, to whom
# {Assessments::SuggestionDismissalVisibility} allows.
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
    dismissed = PersonDevelopment::SuggestionWrites.with_aggregate(evidence_item.person_id, evidence_item.framework_id,
                                                       evidence_ids: [ evidence_item.id ]) do |aggregate|
      next unless suggestion.reload.pending?

      aggregate.dismiss_suggestion(suggestion.id, evidence_id: evidence_item.id, dismissed_by_id: context.person.id,
                                   reason: params[:reason].presence)
      true
    end
    ensure_pending! unless dismissed
    suggestion_payload(suggestion.reload, capability_names([ suggestion ]))
  rescue PersonDevelopment::Aggregate::CommandError => e
    raise Operations::Base::ParameterError, e.message
  end
end
