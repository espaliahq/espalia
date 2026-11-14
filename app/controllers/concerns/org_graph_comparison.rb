# frozen_string_literal: true

# The window "Compare with a date" (#139) reads, kept in the URL as from, to
# and by. Every Org Graph screen reads it here, so the Units view stays
# compared behind a drawer and every link, form and redirect carries it (#156).
module OrgGraphComparison
  extend ActiveSupport::Concern

  included do
    helper_method :comparison_params
  end

  private

  # @return [Hash{Symbol => String}] from, to and by, or none when no date is
  #   picked or the dates make no window
  def comparison_params = comparison_window&.params || {}

  # @param unit_id [String, nil] the unit open on the Units view
  # @return [Hash] the comparison slots for Views::Tenant::OrgGraph::ShowView
  def comparison_slots(unit_id:)
    comparison = comparison_window && OrgGraph::DateComparison.new(context: pundit_user, window: comparison_window)
    {
      comparison_bar: Views::Tenant::OrgGraph::ComparisonBar.new(
        comparison:, error: @comparison_error, values: params.permit(:from, :to, :by).to_h, unit_id:
      ),
      comparison: comparison || OrgGraph::Comparison::NONE
    }
  end

  def comparison_window
    return @comparison_window if defined?(@comparison_window)

    @comparison_window = OrgGraph::DateComparison.window(from: params[:from], to: params[:to], by: params[:by])
  rescue OrgGraph::DateComparison::InvalidWindow => e
    @comparison_error = e.message
    @comparison_window = nil
  end
end
