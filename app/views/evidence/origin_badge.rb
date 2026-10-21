# frozen_string_literal: true

# "via Chip": says a piece of feedback was given in another system and opens
# the original there. Shown on the evidence card, the hub card and the
# activity entry for an item the feedback exchange imported.
#
# @example
#   render Views::Evidence::OriginBadge.new(item.external_reference) if item.external_reference&.imported?
class Views::Evidence::OriginBadge < Views::Base
  SIZES = {
    xs: "px-1.5 py-0.5 text-[10px]",
    sm: "px-2 py-0.5 text-xs"
  }.freeze

  # Neutral and opaque: colour beside feedback already means a rating or a valence.
  BASE = "inline-flex items-center gap-0.5 rounded-full border border-gray-300 bg-white font-medium " \
         "text-gray-700 dark:border-gray-600 dark:bg-gray-900 dark:text-gray-200"

  # @param reference [ExternalReference]
  # @param size [Symbol] :xs or :sm
  def initialize(reference, size: :xs)
    @reference = reference
    @size = size
  end

  def view_template
    classes = "#{BASE} #{SIZES.fetch(@size)}"
    if (url = @reference.safe_url)
      a(href: url, target: "_blank", rel: "noopener noreferrer", data: { origin: @reference.system },
        title: "Open the original in #{label}", class: "#{classes} hover:underline") do
        plain "via #{label}"
        span(aria: { hidden: "true" }) { " ↗" }
        span(class: "sr-only") { " (opens in a new tab)" }
      end
    else
      span(class: classes, data: { origin: @reference.system }) { "via #{label}" }
    end
  end

  private

  def label = Reporting::OriginLabels.peer_label(@reference.system)
end
