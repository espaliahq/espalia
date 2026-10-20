# frozen_string_literal: true

# Small badge indicating the number of pending suggestions on a framework
# entity. Renders nothing when count is zero.
#
# Designed to sit inline in matrix cells, illustration frames, capability
# headers, etc.
#
class Views::Frameworks::Suggestions::InlineIndicator < Views::Base
  # @param count [Integer] number of pending suggestions
  def initialize(count:)
    @count = count
  end

  def view_template
    return if @count.zero?

    span(
      class: "inline-flex items-center rounded-full px-2 py-0.5 text-[10px] font-semibold " \
             "bg-amber-100 text-warning dark:bg-amber-900/30",
      title: "#{@count} pending #{'suggestion'.pluralize(@count)}"
    ) do
      plain "#{@count} pending"
    end
  end
end
