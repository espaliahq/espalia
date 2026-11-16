# frozen_string_literal: true

# What a reader may see of a budget-line change's figures. A line's amount,
# currency and period are pay ([#367](https://github.com/espaliahq/espalia/issues/367)),
# so a member without the see-pay right gets the line without them, and a
# priced line reads exactly as one that only ever held a head count. Every
# read that returns a change's end state asks this.
module Operations::TeamPlanning::LineFigures
  MONEY = %w[amount currency period].freeze
  FACET = ::TeamPlanning::Events::BudgetLineSet.facet

  # @param end_state [Hash, nil] as the read model holds it
  # @param facet [String, nil]
  # @param see_pay [Boolean]
  # @return [Hash, nil]
  def self.end_state(end_state, facet:, see_pay:)
    return end_state if see_pay || facet != FACET || !end_state.is_a?(Hash)

    end_state.except(*MONEY, *MONEY.map(&:to_sym))
  end

  # @param fields [Array<String>] the names of the sealed fields
  # @param facet [String, nil]
  # @param see_pay [Boolean]
  # @return [Array<String>]
  def self.sealed_fields(fields, facet:, see_pay:)
    return fields if see_pay || facet != FACET

    fields.to_a - MONEY
  end
end
