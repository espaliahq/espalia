# frozen_string_literal: true

# Error display rendered via Turbo Stream when a rating fails.
#
class Views::Assessments::RatingError < Views::Base
  # @param message [String]
  def initialize(message:)
    @message = message
  end

  def view_template
    div(class: "p-2 rounded-md bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800") do
      p(class: "text-xs text-red-700 dark:text-red-300") { @message }
    end
  end
end
