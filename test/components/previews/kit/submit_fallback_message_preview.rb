# frozen_string_literal: true

# @label Submit fallback message
class Kit::SubmitFallbackMessagePreview < Lookbook::Preview
  # @param message text
  def playground(message: "Couldn't save this rating — check your connection and try again.")
    revealed("playground", message, classes: "w-max max-w-64")
  end

  # @!group Revealed

  # Under a rating pill
  def rating
    revealed("rating", "Couldn't save this rating — check your connection and try again.",
             classes: "w-max max-w-64")
  end

  # At the top of the feedback modal
  def feedback
    revealed("feedback", "Couldn't save your feedback — check your connection and try again. " \
                         "Your text is still here.",
             classes: "mx-5 mt-4")
  end

  # The server rejected the save (a stale page, an expired session)
  def rejected
    revealed("rejected", "Couldn't save — the page may be out of date. Reload and try again.",
             classes: "w-max max-w-64")
  end

  # @!endgroup

  private

  def revealed(id, message, classes:)
    render_with_template(
      template: "kit/submit_fallback_message_preview/revealed",
      locals: { id: "submit-fallback-#{id}", message: message, classes: classes }
    )
  end
end
