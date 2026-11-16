# frozen_string_literal: true

# Header pill that opens and closes the assessment's activity pane, with the
# number of entries in it. The pane is a `Kit::SidePanel` around the whole
# page, so this toggle can sit in the sticky header.
#
class Views::Assessments::Activity::PaneToggle < Views::Base
  PANE_ID = "assessment-activity-pane"
  COOKIE = "assessment_activity_pane_open"
  URL_KEY = "activity"

  # Whether the pane renders open: closed on a first visit, where the matrix
  # is the point and the feed its companion.
  #
  # @param url [String, nil] the `?activity=` value
  # @param cookie [String, nil] the cookie's value
  def self.open?(url:, cookie:) = Components::Kit::SidePanel.open?(url:, cookie:, default: false)

  # @param entry_count [Integer] total entries currently shown in the pane
  # @param open [Boolean] whether the pane renders open
  def initialize(entry_count:, open:)
    @entry_count = entry_count
    @open = open
  end

  def view_template
    render Components::Kit::SidePanel::Toggle.new(controls: PANE_ID, open: @open, variant: :subtle, compact: true) do
      span { "Activity" }
      span(class: "text-xs font-mono text-muted") { @entry_count.to_s }
    end
  end
end
