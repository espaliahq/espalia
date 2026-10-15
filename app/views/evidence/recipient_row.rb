# frozen_string_literal: true

# One person the giver can pick in the "Give feedback" step: a link that
# navigates the `#evidence-modal` frame to the `:new` form for that person's
# assignment. The same row serves the suggestions list and the typeahead
# results.
class Views::Evidence::RecipientRow < Views::Base
  RELATIONSHIP_LABELS = { "report" => "your report", "manager" => "your manager", "peer" => nil }.freeze

  # @param recipient [Assessments::FeedbackRecipients::Recipient]
  # @param return_to [String]
  def initialize(recipient:, return_to:)
    @recipient = recipient
    @return_to = return_to
  end

  def view_template
    a(href: evidence_modal_path(mode: "new", assignment_id: @recipient.assignment.id, return_to: @return_to),
      data: { turbo_frame: "evidence-modal", recipient_row: "", person_id: @recipient.person.id },
      class: "flex w-full items-center justify-between gap-3 min-h-11 px-3 py-2 rounded-md " \
             "hover:bg-gray-50 dark:hover:bg-gray-800") do
      div(class: "min-w-0 text-left") do
        p(class: "truncate text-sm font-medium text-gray-900 dark:text-gray-100") { @recipient.person.name }
        p(class: "truncate text-xs text-gray-600 dark:text-gray-300") { secondary }
      end
      span(class: "shrink-0 text-xs font-medium text-primary-ink") { "Give feedback" }
    end
  end

  private

  # The email leads so a row that matched on it, not the name, explains itself.
  def secondary
    assignment = @recipient.assignment
    [ @recipient.person.email, assignment.role&.name, assignment.level&.code,
      RELATIONSHIP_LABELS[@recipient.relationship] ].compact.join(" · ")
  end
end
