# frozen_string_literal: true

# Turbo Frame wrapper for the assessment activity feed.
#
# Rendered standalone by Assessments::ActivityController#show — the
# response body for ActionCable-triggered reloads. ShowView renders
# the inner {Feed} body directly inside its own turbo_frame_tag.
#
class Views::Assessments::Activity::FeedFrameView < Views::Base
  include Phlex::Rails::Helpers::TurboFrameTag

  # @param entries [Array<Assessments::ActivityFeedQuery::Entry>]
  # @param assignment [PersonFrameworkAssignment]
  def initialize(entries:, assignment:)
    @entries = entries
    @assignment = assignment
  end

  def view_template
    turbo_frame_tag("assessment-activity") do
      render Views::Assessments::Activity::Feed.new(
        entries: @entries,
        assignment: @assignment
      )
    end
  end
end
