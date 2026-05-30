# frozen_string_literal: true

# Renders a divergent secondary perspective as a text line:
#
#   ○ Self rated: most of the time
#
# Replaces the previous {FrequencyBar} for the secondary slot. The bar
# duplicated the value visually (label + filled bar + label) and ate
# vertical space; a single text line with a colour-coded dot is
# enough to read the value AND signal divergence.
#
# Returns nothing when the secondary frequency is absent or equal to
# the primary — divergence is the entire point of the line, so showing
# it when self and primary agree is just noise.
#
# @example
#   render Views::Assessments::SecondaryRatingLine.new(
#     label: "Self", frequency: "some", primary_frequency: "consistent"
#   )
#
class Views::Assessments::SecondaryRatingLine < Views::Base
  # @param label [String] "Self", "Mgr", or "Agreed"
  # @param frequency [String, nil]
  # @param primary_frequency [String, nil]
  def initialize(label:, frequency:, primary_frequency: nil)
    @label = label
    @frequency = frequency
    @primary_frequency = primary_frequency
  end

  def view_template
    return unless renderable?

    config = Views::Assessments::FrequencyPalette.config_for(@frequency)
    return unless config

    # Inline-flex so multiple secondaries (alignment view: Self + Manager)
    # sit beside each other on the same line as the pill, separated by
    # the parent's flex `gap`. Dot precedes the label per the design;
    # phrase keeps the pill's natural case ("Most of the time", not
    # "most of the time") for a single consistent vocabulary.
    span(class: "inline-flex items-center gap-1.5 text-xs text-gray-600 dark:text-gray-400") do
      span(class: "w-2 h-2 rounded-full #{config[:dot]} shrink-0",
           aria: { hidden: "true" })
      span do
        plain "#{@label} rating: "
        span(class: "font-medium text-gray-800 dark:text-gray-200") { config[:phrase] }
      end
    end
  end

  private

  def renderable?
    return false if @frequency.blank?
    return false if @primary_frequency.present? && @frequency == @primary_frequency

    true
  end
end
