# frozen_string_literal: true

# The line under the header on a past cycle's page: which cycle this is, that
# it ended, how far the alignment got, that the page is read-only, and the
# way back to the open cycle. It stands in for the status pill, whose calls
# to action belong to a cycle still running
# (https://github.com/mr-yum/growth-os/issues/669).
class Views::Assessments::PastCycleBanner < Views::Base
  ID = "assessment-past-cycle-banner"

  # @param lens [Assessments::Lens] a lens on a past cycle
  # @param assessment_id [String]
  # @param has_open_cycle [Boolean] the person is in an open cycle to go back to
  def initialize(lens:, assessment_id:, has_open_cycle:)
    @lens = lens
    @assessment_id = assessment_id
    @has_open_cycle = has_open_cycle
  end

  def view_template
    p(id: ID, class: "mt-1 text-sm text-muted", data: { cycle_id: @lens.cycle.cycle_id }) do
      strong(class: "font-semibold text-default") { @lens.cycle.name }
      plain " #{ended}. #{alignment}. Read-only. "
      back_link if @has_open_cycle
    end
  end

  private

  def ended
    return "· withdrawn" if withdrawn?

    closed_at = @lens.cycle.closed_at
    closed_at ? "closed on #{closed_at.strftime('%-d %b %Y')}" : "has closed"
  end

  def alignment
    aligned_at = @lens.participation&.progress&.aligned_at
    return "Aligned on #{aligned_at.strftime('%-d %b %Y')}" if aligned_at
    return "Alignment started but wasn't completed" if @lens.participant_status == "aligning"

    "Alignment didn't start"
  end

  def withdrawn?
    @lens.participation&.enrollment&.status == "withdrawn"
  end

  def back_link
    a(href: assessment_path(@assessment_id),
      class: "font-medium text-brand hover:underline whitespace-nowrap rounded-sm " \
             "focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-focus") do
      "← Back to the open cycle"
    end
  end
end
