# frozen_string_literal: true

# Sticky left-column cell for a capability row in the assessment matrix.
#
# Independently renderable so the Turbo Stream response can replace it
# when a rating change updates blocked status.
#
class Views::Assessments::CapabilityNameCell < Views::Base
  # @param capability [#stable_id, #capability_id, #name, #description] capability read model
  # @param weight [Float] binding weight
  # @param mandatory [Boolean] whether deficit_threshold is 0
  # @param blocked [Boolean] whether this capability is blocked at person_level
  # @param block_reason [String, nil] human-readable explanation for why it's blocked
  # @param contribution [Float, nil] raw contribution score
  # @param has_illustrations [Boolean] whether expandable illustrations exist
  def initialize(capability:, weight:, mandatory:, blocked:, contribution:, has_illustrations:, block_reason: nil)
    @capability = capability
    @weight = weight
    @mandatory = mandatory
    @blocked = blocked
    @block_reason = block_reason
    @contribution = contribution
    @has_illustrations = has_illustrations
  end

  def view_template
    td(id: "capability-name-#{@capability.stable_id}",
       class: "sticky left-0 z-[2] bg-white dark:bg-gray-900 " \
              "px-4 py-2.5 border-b border-r border-gray-100 dark:border-gray-800 " \
              "min-w-[220px] align-top " \
              "hover:bg-gray-50 dark:hover:bg-gray-800/50 " \
              "#{left_border_class}") do
      div(class: "flex items-start gap-2") do
        chevron_icon if @has_illustrations
        div do
          div(class: "flex items-center gap-1.5") do
            span(class: "text-sm font-medium text-gray-900 dark:text-white") { @capability.name }
            render Components::Kit::WeightBadge.new(weight: @weight, mandatory: @mandatory)
            blocked_badge if @blocked
            render Views::Assessments::ContributionLabel.new(
              capability_stable_id: @capability.stable_id, contribution: @contribution
            )
          end
          if @capability.description.present?
            p(class: "text-xs text-gray-500 dark:text-gray-400 mt-0.5 line-clamp-2") do
              @capability.description
            end
          end
          if @block_reason
            p(class: "text-[10px] text-red-600 dark:text-red-400 mt-0.5") { @block_reason }
          end
        end
      end
    end
  end

  private

  def left_border_class
    if @blocked
      "border-l-3 border-l-red-400"
    elsif @mandatory
      "border-l-3 border-l-amber-400"
    else
      ""
    end
  end

  def blocked_badge
    span(class: "inline-flex items-center rounded-full px-1.5 py-0.5 text-[10px] font-semibold " \
                "bg-red-100 text-red-800 dark:bg-red-900/30 dark:text-red-300",
         title: @block_reason) do
      "Blocked"
    end
  end

  def chevron_icon
    svg(
      class: "w-3 h-3 mt-1 text-gray-400 transition-transform shrink-0",
      data: { matrix_target: "rowChevron" },
      fill: "none", viewBox: "0 0 24 24", stroke: "currentColor", stroke_width: "2"
    ) do |s|
      s.path(d: "M9 5l7 7-7 7")
    end
  end
end
