# frozen_string_literal: true

# Category pass/fail badge for Turbo Stream targeting.
# Rendered inline in category headers and in the scoring panel.
#
class Views::Assessments::CategoryStatus < Views::Base
  # @param category_id [String]
  # @param category_result [Hash, nil] { pass: Boolean, pool: Float }
  def initialize(category_id:, category_result:)
    @category_id = category_id
    @category_result = category_result
  end

  def view_template
    span(id: "category-status-#{@category_id}") do
      if @category_result.nil?
        render Components::Kit::Badge.new("N/A", variant: :default)
      elsif @category_result[:pass]
        render Components::Kit::Badge.new("Pass", variant: :success)
      else
        render Components::Kit::Badge.new("Below", variant: :warning)
      end
    end
  end
end
