# frozen_string_literal: true

# The directory behind "who can I give feedback to?" — colleagues with a
# framework assignment, found by name or email, or the caller's org
# neighbours when no query is given. Each row carries the assignment id
# `assessments_record_evidence` needs, so volunteering feedback to a peer is
# two calls: this, then that.
#
# A peer may not open another person's assessment (AssessmentPolicy#show?),
# which is why this exists: `assessments_mine` lists only the assignments the
# caller owns or reviews, and nothing else resolved a colleague to one.
# Read-only; any member with a Person record may search
# (AssessmentPolicy#index?).
class Operations::Assessments::FeedbackRecipients < Operations::Base
  description "Find colleagues you can give feedback to: people with a framework assignment, by name or email, " \
              "or your manager, peers and reports when no query is given. Each row carries the assignment_id " \
              "to pass to assessments_record_evidence; a peer cannot read the assessment itself."
  category :read
  approval :none

  parameter :query, String
  parameter :limit, Integer

  def policy_check
    raise Pundit::NotAuthorizedError, "not linked to a person" if context.person.nil?

    authorize PersonFrameworkAssignment, :index?
  end

  # @return [Hash] `{ recipients: [{ person{id,name,email}, relationship,
  #   assignment_id, framework{id,name}, role{id,code,name},
  #   level{id,ordinal,title,code} }] }`, relationship from the caller's side:
  #   "report" (they report to the caller), "manager" (the caller reports to
  #   them) or "peer".
  def perform
    recipients = Assessments::FeedbackRecipients.new(giver: context.person)
      .call(params[:query], limit: params[:limit] || Assessments::FeedbackRecipients::DEFAULT_LIMIT)

    { recipients: recipients.map { |r| recipient_payload(r) } }
  end

  private

  def recipient_payload(recipient)
    assignment = recipient.assignment
    {
      person: { id: recipient.person.id, name: recipient.person.name, email: recipient.person.email },
      relationship: recipient.relationship,
      assignment_id: assignment.id,
      framework: assignment.framework && { id: assignment.framework.framework_id, name: assignment.framework.name },
      role: assignment.role && { id: assignment.role.role_id, code: assignment.role.code, name: assignment.role.name },
      level: assignment.level && {
        id: assignment.level.level_id, ordinal: assignment.level.ordinal,
        title: assignment.level.title, code: assignment.level.code
      }
    }
  end
end
