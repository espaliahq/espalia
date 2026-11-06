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
# Alignment wins once the manager has formally started it against the role
# being read (ADR-22) — both parties then view in alignment mode, with no
# opt-in. The home role's alignment decides the home lens (at any level); a
# lens on another role reads as alignment only once alignment has started
# against that role. Until then the per-cell disclosure decides what the
# assessee sees of the cells another conversation opened.
class Assessments::ViewerContext
  # @param assignment [PersonFrameworkAssignment]
  # @param authorization [AuthorizationContext] the viewer's identity chain
  # @param lens [Assessments::Lens, nil] the role the page is read against;
  #   nil reads the home role
  # @return [Symbol] :self, :manager or :alignment
  def self.for(assignment:, authorization:, lens: nil)
    role_id = lens.role.role_id unless lens.nil? || lens.home_role?
    cycle = lens.cycle if lens&.past?
    return :alignment if AssessmentPolicy.new(authorization, assignment).view_alignment?(role_id: role_id, cycle: cycle)

    assignment.person_id == authorization.person&.id ? :self : :manager
  end
end
