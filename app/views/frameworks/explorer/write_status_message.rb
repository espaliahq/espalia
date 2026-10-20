# frozen_string_literal: true

# One transient message inside the explorer's write-status region
# ({Views::Frameworks::Explorer::WriteStatus}).
#
# Two tones, matching the app's existing flash vocabulary so the explorer's
# feedback doesn't invent a second visual language:
#
# - `:ok` — the write landed. The copy distinguishes **applied** ("Saved",
#   "Archived …") from **proposed** ("Proposed for review"), because the
#   editing/suggesting toggle plus the viewer's approval authority decide which
#   happened and the user cannot otherwise tell.
# - `:error` — the write was refused. Kept in the same region rather than
#   redirecting, so a failed write never costs the user their scroll position
#   or their open expanded row.
#
# Auto-dismisses via the shared `flash` Stimulus controller.
#
class Views::Frameworks::Explorer::WriteStatusMessage < Views::Base
  TONES = {
    ok: { tone: :success, delay: 4000 },
    error: { tone: :danger, delay: 7000 }
  }.freeze

  # @param message [String] the user-facing sentence
  # @param tone [Symbol] :ok or :error
  def initialize(message:, tone: :ok)
    @message = message
    @tone = TONES.key?(tone) ? tone : :ok
  end

  def view_template
    tone = TONES[@tone]
    render Components::Kit::Toast.new(tone: tone[:tone], dismiss_after: tone[:delay]) { @message }
  end
end
