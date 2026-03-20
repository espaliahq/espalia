# frozen_string_literal: true

# Displays category deficit threshold level in category headers.
#
# - nil → renders nothing (inherits framework default)
# - 0   → lock icon + "Must balance"
# - > 0 → "± N pts" label
#
class Components::Kit::CategoryToleranceIndicator < Components::Base
  # @param threshold [Float, nil] the category's deficit_threshold
  def initialize(threshold:)
    @threshold = threshold
  end

  def view_template
    return if @threshold.nil?

    if @threshold.zero?
      zero_threshold
    else
      capped_threshold
    end
  end

  private

  def zero_threshold
    span(class: "inline-flex items-center gap-1 text-[10px] font-medium " \
                "text-amber-700 dark:text-amber-400") do
      lock_icon
      plain "Must balance"
    end
  end

  def capped_threshold
    formatted = @threshold == @threshold.to_i ? @threshold.to_i.to_s : @threshold.to_s
    span(class: "inline-flex items-center text-[10px] font-medium " \
                "text-gray-500 dark:text-gray-400 bg-gray-100 dark:bg-gray-700 " \
                "rounded-full px-1.5 py-0.5") do
      plain "\u00B1 #{formatted} pts"
    end
  end

  def lock_icon
    svg(class: "w-3 h-3", fill: "none", viewBox: "0 0 24 24",
        stroke: "currentColor", stroke_width: "2") do |s|
      s.path(
        d: "M12 15v2m-6 4h12a2 2 0 002-2v-6a2 2 0 00-2-2H6a2 2 0 00-2 2v6a2 2 0 002 2z" \
           "m13-9V9a5 5 0 00-10 0v3h10z"
      )
    end
  end
end
