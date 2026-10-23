# frozen_string_literal: true

# Error display rendered via Turbo Stream when a rating fails.
#
class Views::Assessments::RatingError < Views::Base
  # @param message [String]
  def initialize(message:)
    @message = message
  end

  def view_template
    render Components::Kit::Alert.new(tone: :danger, size: :sm) { @message }
  end
end
