# frozen_string_literal: true

# Header status pill for the self-assessment and manager-review screens.
#
# Wrapped in a stable `id="assessment-status-pill"` element so rating
# controllers can Turbo-replace it the moment the final current-level cell is
# rated — flipping "In Progress" to its finished label without a reload.
#
# The finished label depends on whose work the pill describes. An assessee who
# has rated every current-level cell reads "Ready for alignment": their part is
# done and the next step is the manager's. A manager who has rated every cell
# reads "Assessment Complete". Both precede the manager-driven "Aligning" /
# "Aligned" lifecycle phases.
#
class Views::Assessments::StatusPill < Views::Base
  WRAPPER_ID = "assessment-status-pill"
  READY_FOR_ALIGNMENT = "Ready for alignment"
  READY_FOR_ALIGNMENT_DEFINITION =
    "You've rated every capability at your level. Your manager starts alignment next."

  # @param participant_status [String, nil] cycle participation status
  # @param has_open_cycle [Boolean] whether an assessment cycle is open
  # @param current_level_complete [Boolean] all current-level cells rated
  # @param context [Symbol] :self (the assessee's view) or :manager
  def initialize(participant_status:, has_open_cycle:, context:, current_level_complete: false)
    @participant_status = participant_status
    @has_open_cycle = has_open_cycle
    @current_level_complete = current_level_complete
    @context = context
  end

  def view_template
    span(id: WRAPPER_ID, class: "inline-flex") { pill }
  end

  private

  def pill
    case @participant_status
    when "aligning" then render Components::Kit::Badge.new("Aligning", variant: :warning)
    when "aligned"  then render Components::Kit::Badge.new("Aligned", variant: :success)
    else
      return unless @has_open_cycle

      if !@current_level_complete
        render Components::Kit::Badge.new("In Progress", variant: :warning)
      elsif @context == :self
        ready_for_alignment
      else
        render Components::Kit::Badge.new("Assessment Complete", variant: :success)
      end
    end
  end

  # Says whose move it is on hover AND keyboard focus — a `title` would leave
  # keyboard and screen-reader users with the label alone.
  def ready_for_alignment
    render Components::Kit::DefinitionTip.new(
      READY_FOR_ALIGNMENT,
      definition: READY_FOR_ALIGNMENT_DEFINITION,
      id: "#{WRAPPER_ID}-definition",
      trigger_class: "min-h-6 #{Components::Kit::Badge.classes(:success)}"
    )
  end
end
