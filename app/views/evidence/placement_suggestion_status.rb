# frozen_string_literal: true

# What just happened to an item's placement suggestions, written into its
# persistent status line by the accept / dismiss / suggest responses.
class Views::Evidence::PlacementSuggestionStatus < Views::Base
  # @param message [String]
  # @param error [Boolean]
  def initialize(message:, error: false)
    @message = message
    @error = error
  end

  def view_template
    p(class: "text-sm #{@error ? 'text-danger' : 'text-success'}") { @message }
  end
end
