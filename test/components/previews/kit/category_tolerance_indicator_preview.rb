# frozen_string_literal: true

# @label Category tolerance indicator
class Kit::CategoryToleranceIndicatorPreview < Lookbook::Preview
  # @param threshold [Float] number { step: 0.5 }
  def playground(threshold: 1.5)
    render Components::Kit::CategoryToleranceIndicator.new(threshold: threshold)
  end

  # @!group Thresholds

  def must_balance
    render Components::Kit::CategoryToleranceIndicator.new(threshold: 0)
  end

  def whole_points
    render Components::Kit::CategoryToleranceIndicator.new(threshold: 2.0)
  end

  def fractional_points
    render Components::Kit::CategoryToleranceIndicator.new(threshold: 1.5)
  end

  # Renders nothing: the category inherits the framework default
  def inherited
    render Components::Kit::CategoryToleranceIndicator.new(threshold: nil)
  end

  # @!endgroup
end
