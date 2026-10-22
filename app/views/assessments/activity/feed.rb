# frozen_string_literal: true

# Body of the activity feed sidebar — header + entries (or empty state).
# Used inline by ShowView/ManagerShowView (inside their turbo_frame_tag
# wrapper for the activity pane) AND inside FeedFrameView for standalone
# renders triggered by the assessment_updates ActionCable channel.
#
class Views::Assessments::Activity::Feed < Views::Base
  # @param entries [Array<Assessments::ActivityFeedQuery::Entry>]
  # @param assignment [PersonFrameworkAssignment]
  def initialize(entries:, assignment:)
    @entries = entries
    @assignment = assignment
  end

  def view_template
    div(
      class: "p-4",
      data: {
        controller: "activity-feed",
        action: "matrix:focus-changed@window->activity-feed#onMatrixFocusChanged"
      }
    ) do
      header
      filter_row
      focus_banner
      if @entries.empty?
        empty_state
      else
        ul(class: "space-y-1") do
          @entries.each do |entry|
            render Views::Assessments::Activity::Entry.new(entry: entry, assignment: @assignment)
          end
        end
      end
    end
  end

  private

  # Single header for the pane — title + live entry count on the left,
  # the close button on the right. Lives inside the turbo-frame
  # (this component) so the count re-renders when ActionCable
  # broadcasts a fresh feed. The previous layout duplicated "Activity"
  # — once here in the feed, once in a wrapper `activity_sidebar_header`
  # outside the frame — taking up two rows for one piece of context.
  def header
    div(class: "mb-3 flex items-center justify-between gap-2") do
      div(class: "flex items-baseline gap-2 min-w-0") do
        h2(class: "text-sm font-semibold text-default truncate") { "Activity" }
        span(class: "text-[11px] text-muted shrink-0") do
          "#{@entries.size} #{@entries.size == 1 ? 'event' : 'events'}"
        end
      end
      render Components::Kit::Button.new(variant: :ghost, size: :xs, icon: true, touch: true, aria_label: "Close activity",
                                         data: { action: "click->activity-pane#close" }) { plain "×" }
    end
  end

  def filter_row
    div(class: "mb-3 flex flex-wrap items-center justify-between gap-2") do
      render Views::Assessments::Activity::FilterChips.new
      render Views::Assessments::Activity::FocusModeToggle.new
    end
  end

  # In Filter mode + an active focus, surface a small banner so the
  # narrowed list is obviously narrowed. Hidden by default; the
  # activity-feed Stimulus controller toggles `hidden` based on state.
  # The "Show all activity" link inside dispatches activity-feed#clearFocus
  # to reset the feed's internal focus without collapsing the matrix.
  def focus_banner
    render Components::Kit::Alert.new(tone: :warning, size: :sm, class: "hidden mb-2",
                                      data: { activity_feed_target: "focusBanner" }) do
      div(class: "flex items-center justify-between gap-2") do
        span do
          plain "Showing entries "
          span(data: { activity_feed_target: "focusBannerLabel" }) { "for the focused capability" }
        end
        button(type: "button", class: "font-medium hover:underline cursor-pointer",
               data: { action: "click->activity-feed#clearFocus" }) { "Show all activity" }
      end
    end
  end

  def empty_state
    render Components::Kit::EmptyState.new(title: "No activity yet", size: :panel) do
      "Record feedback or update a rating to begin."
    end
  end
end
