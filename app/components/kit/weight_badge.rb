# frozen_string_literal: true

# Displays capability weight and mandatory status indicators.
#
# - weight != 1.0 → shows "2×" (or formatted weight)
# - mandatory (individual_tolerance == 0) → solid amber variant
# - weight == 1.0 and not mandatory → renders nothing
#
class Components::Kit::WeightBadge < Components::Base
  # @param weight [Float] the binding weight multiplier
  # @param mandatory [Boolean] true when individual_tolerance == 0
  def initialize(weight:, mandatory:)
    @weight = weight
    @mandatory = mandatory
  end

  def view_template
    return if @weight == 1.0 && !@mandatory

    if @weight != 1.0 && @mandatory
      # Show both weight and mandatory indicators
      span(class: mandatory_classes) { "#{format_weight}×" }
    elsif @weight != 1.0
      span(class: weight_classes) { "#{format_weight}×" }
    else
      span(class: mandatory_classes) { "Required" }
    end
  end

  def format_weight
    @weight == @weight.to_i ? @weight.to_i.to_s : @weight.to_s
  end

  def mandatory_classes
    "#{base_classes} bg-amber-100 text-amber-800 dark:bg-amber-900/30 dark:text-amber-300"
  end

  def weight_classes
    "#{base_classes} bg-gray-100 text-gray-600 dark:bg-gray-700 dark:text-gray-300"
  end

  def base_classes
    "inline-flex items-center rounded-full px-1.5 py-0.5 text-[10px] font-semibold"
  end
end
