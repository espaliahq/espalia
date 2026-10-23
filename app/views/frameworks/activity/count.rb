# frozen_string_literal: true

# The activity feed's loaded-entry count (header subtext). Its own component
# with a stable id so the "load older" Turbo Stream can replace it with the new
# running total as older batches are appended.
class Views::Frameworks::Activity::Count < Views::Base
  # @param total [Integer] entries loaded so far
  def initialize(total:)
    @total = total
  end

  def view_template
    p(id: "framework-activity-count", class: "text-xs text-muted mt-0.5") do
      "#{@total} #{@total == 1 ? 'event' : 'events'}"
    end
  end
end
