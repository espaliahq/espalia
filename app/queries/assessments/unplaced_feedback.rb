# frozen_string_literal: true

# How much feedback is waiting to be placed on an assessment, for a viewer who
# may place it — the ONE answer the assessment's notice and `assessments_get`
# both give, so an agent never reports a count the person's screen withholds.
# A viewer who sees the evidence but may not decide where it belongs (a tenant
# admin outside the chain, by EvidencePolicy#add_link?) gets nil, as does a
# peer, who is told nothing of others' items.
class Assessments::UnplacedFeedback
  # @param assignment [PersonFrameworkAssignment]
  # @param context [AuthorizationContext]
  # @return [Integer, nil] the count, or nil when the viewer may not place
  def self.count_for(assignment:, context:)
    return nil if context.person.nil? || !EvidencePolicy.new(context, assignment).index?

    scope = EvidenceItem.unplaced.for_person(assignment.person_id).for_framework(assignment.framework_id)
    probe = scope.first
    return 0 if probe.nil?
    return nil unless EvidencePolicy.new(context, probe).add_link?

    scope.count
  end
end
