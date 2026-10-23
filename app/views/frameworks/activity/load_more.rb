# frozen_string_literal: true

# The activity feed's "load older" footer — the indication that more activity
# exists beyond the recency-capped batch (see Frameworks::ActivityFeedQuery's
# STREAM_READ_LIMIT) plus the affordance to fetch the next batch.
#
# Always renders the stable `#framework-activity-load-more` container (so the
# Turbo Stream "load older" response can replace it with the next cursor — or
# empty it when the feed is exhausted). The button fetches the next batch via
# the `activity-more` controller (@rails/request.js → turbo_stream append).
class Views::Frameworks::Activity::LoadMore < Views::Base
  # @param has_more [Boolean]
  # @param load_more_path [String, nil] URL for the next (older) batch
  def initialize(has_more:, load_more_path: nil)
    @has_more = has_more
    @load_more_path = load_more_path
  end

  def view_template
    div(id: "framework-activity-load-more", class: "mt-2") do
      next unless @has_more && @load_more_path

      div(data: { controller: "activity-more", activity_more_url_value: @load_more_path }) do
        render Components::Kit::Button.new(
          variant: :outline, size: :sm, class: "w-full",
          data: { action: "activity-more#load", activity_more_target: "button" }
        ) { "Load older activity" }
      end
    end
  end
end
