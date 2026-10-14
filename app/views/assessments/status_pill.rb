# frozen_string_literal: true

# Header status pill for the self-assessment and manager-review screens.
#
# Wrapped in a stable `id="assessment-status-pill"` element so rating
# controllers can Turbo-replace it the moment the final current-level cell is
# rated — flipping "In Progress" to "Assessment Complete" without a reload.
#
# "Assessment Complete" rewards finishing the current-level ratings (100%
# coverage in the viewer's perspective); it precedes the manager-driven
# "Aligning" / "Aligned" lifecycle phases. When every cell holds a value but
# some were carried from the last cycle, it says how many are left to confirm
# rather than a bare "In Progress" that reads as finished work undone (#480).
#
class Views::Assessments::StatusPill < Views::Base
  WRAPPER_ID = "assessment-status-pill"

  # @param participant_status [String, nil] cycle participation status
  # @param has_open_cycle [Boolean] whether an assessment cycle is open
  # @param current_level_complete [Boolean] all current-level cells rated
  # @param work [Hash] the builder's `current_level_work` — :unrated, :to_confirm
  def initialize(participant_status:, has_open_cycle:, current_level_complete: false, work: {})
    @participant_status = participant_status
    @has_open_cycle = has_open_cycle
    @current_level_complete = current_level_complete
    @work = work || {}
  end

  def view_template
    span(id: WRAPPER_ID, class: "inline-flex") { pill }
  end

  private

  def only_confirmations_left?
    @work[:unrated].to_i.zero? && @work[:to_confirm].to_i.positive?
  end

  def pill
    case @participant_status
    when "aligning" then render Components::Kit::Badge.new("Aligning", variant: :warning)
    when "aligned"  then render Components::Kit::Badge.new("Aligned", variant: :success)
    else
      return unless @has_open_cycle

      if @current_level_complete
        render Components::Kit::Badge.new("Assessment Complete", variant: :success)
      elsif only_confirmations_left?
        render Components::Kit::ToConfirmChip.new(
          "#{@work[:to_confirm]} to confirm",
          title: "Carried from the last cycle — confirm each one or change it to complete your assessment"
        )
      else
        render Components::Kit::Badge.new("In Progress", variant: :warning)
      end
    end
  end
end
