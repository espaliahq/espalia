# frozen_string_literal: true

# Segmented filter chips above the activity feed. Switches the visible
# entry kinds between All / Ratings / Evidence / Alignment via the
# activity_feed Stimulus controller (purely client-side — DOM filter,
# no server round-trip).
#
# Each chip's value lives in `data-activity-feed-filter-param`, which
# the controller reads when the chip is clicked. The pressed state is
# driven by `aria-pressed`, set initially in this view and re-painted
# by the controller after every filter change.
#
class Views::Assessments::Activity::FilterChips < Views::Base
  CHIPS = [
    { value: "all",       label: "All" },
    { value: "ratings",   label: "Ratings" },
    { value: "evidence",  label: "Evidence" },
    { value: "comments",  label: "Comments" },
    { value: "alignment", label: "Alignment" }
  ].freeze

  def view_template
    div(
      class: "flex flex-wrap gap-1 text-[11px] font-medium",
      role: "group",
      aria_label: "Filter activity by kind"
    ) do
      CHIPS.each { |chip| render_chip(chip) }
    end
  end

  private

  def render_chip(chip)
    button(
      type: "button",
      class: "px-2 py-1 rounded-md transition-colors " \
             "aria-pressed:bg-primary aria-pressed:text-white " \
             "aria-[pressed=false]:bg-gray-100 dark:aria-[pressed=false]:bg-gray-800 " \
             "aria-[pressed=false]:text-gray-600 dark:aria-[pressed=false]:text-gray-300 " \
             "aria-[pressed=false]:hover:bg-gray-200 dark:aria-[pressed=false]:hover:bg-gray-700",
      data: {
        activity_feed_target: "filterChip",
        activity_feed_filter_param: chip[:value],
        action: "click->activity-feed#setFilter"
      },
      aria: { pressed: chip[:value] == "all" ? "true" : "false" }
    ) { chip[:label] }
  end
end
