# frozen_string_literal: true

# A Slack feedback draft opens only for the account whose email it was
# written for — the controller checks the email, this keeps the action under
# Pundit like every other.
class FeedbackDraftPolicy < ApplicationPolicy
  # @return [Boolean]
  def show?
    user.present? && user.email.to_s.strip.casecmp?(record.author_email)
  end
end
