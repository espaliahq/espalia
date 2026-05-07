# frozen_string_literal: true

# Segmented filter chips above the activity feed. Switches the visible
# entry kinds between All / Ratings / Evidence / Alignment via the
# activity_feed Stimulus controller (purely client-side — DOM filter,
# no server round-trip).
#
# Each chip's pressed-state is driven by `data-activity-feed-filter-value`
# read by the controller on connect; the active chip carries the
# `aria-pressed="true"` styling, others get the inactive styling.
#
class Views::Assessments::Activity::FilterChips < Views::Base
  CHIPS = [
    { value: "all",       label: "All" },
    { value: "ratings",   label: "Ratings" },
    { value: "evidence",  label: "Evidence" },
    { value: "alignment", label: "Alignment" }
  ].freeze

  def view_template
    div(
      class: "flex gap-1 text-[11px] font-medium",
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
