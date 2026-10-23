# frozen_string_literal: true

# The "Give feedback" step's typeahead results — a floating panel of
# {RecipientRow}s, replaced on each debounced keystroke (the frame `src`
# carries the query). Empty until there is a query.
class Views::Evidence::RecipientCandidatesFrame < Views::Base
  PANEL = "rounded-md border border-default bg-overlay " \
          "shadow-lg max-h-64 overflow-y-auto"

  # @param entries [Array<Assessments::FeedbackRecipients::Recipient>]
  # @param query [String, nil]
  # @param return_to [String]
  # @param draft_token [String, nil]
  def initialize(entries:, query:, return_to:, draft_token: nil)
    @entries = entries
    @query = query
    @return_to = return_to
    @draft_token = draft_token
  end

  def view_template
    turbo_frame_tag(Views::Evidence::RecipientPickerForm::FRAME_ID) do
      panel unless @query.blank?
    end
  end

  private

  def panel
    div(class: PANEL) do
      if @entries.empty?
        p(class: "px-3 py-3 text-xs text-muted") do
          "No one matching “#{@query}” has an assessment to give feedback on."
        end
      else
        div(class: "divide-y divide-subtle") do
          @entries.each do |recipient|
            render Views::Evidence::RecipientRow.new(recipient: recipient, return_to: @return_to, draft_token: @draft_token)
          end
        end
      end
    end
  end
end
