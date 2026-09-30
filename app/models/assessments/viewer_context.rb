# frozen_string_literal: true

# Which of the three assessment perspectives a viewer is looking through:
# `:self`, `:manager` or `:alignment`.
#
# One definition, because both surfaces depend on it and they must agree:
# the web threads it into `Assessments::MatrixDataBuilder` (which scrubs
# manager and aligned ratings when it is `:self` — see assessments.md's
# self-assessment privacy rule), and the MCP read tools thread it into
# {Assessments::ScoreSummary}, whose numbers are built from those same
# scrubbed ratings. A second, drifting copy would let an agent read a
# score the assessee is not allowed to see.
#
# Alignment wins once the manager has formally started it — both parties
# then view in alignment mode, with no opt-in. Alignment is started against
# the home role (ADR-22), so a lens on another role never reads as
# alignment: nothing has been started against that role, and the per-cell
# disclosure decides what the assessee sees of the shared cells.
class Assessments::ViewerContext
  # @param assignment [PersonFrameworkAssignment]
  # @param authorization [AuthorizationContext] the viewer's identity chain
  # @param lens [Assessments::Lens, nil] the role the page is read against;
  #   nil reads the home role
  # @return [Symbol] :self, :manager or :alignment
  def self.for(assignment:, authorization:, lens: nil)
    alignment_role = lens.nil? || lens.home_role?
    return :alignment if alignment_role && AssessmentPolicy.new(authorization, assignment).view_alignment?

    assignment.person_id == authorization.person&.id ? :self : :manager
  end
end
