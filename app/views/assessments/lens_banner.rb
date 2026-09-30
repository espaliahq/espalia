# frozen_string_literal: true

# The lines that replace the status pill while a lens is on (ADR-22): what
# the page is read against, that the record is untouched, and the way back —
# then where the conversation about the lens role stands. The status pill
# describes the record's lifecycle, which a lens neither reads nor changes,
# so the two never show together.
#
# Alignment against the lens role is the one deliberate act that shares the
# manager's ratings there, so the manager is told their ratings are private
# until they start it, and offered the start.
class Views::Assessments::LensBanner < Views::Base
  ID = "assessment-lens-banner"
  ALIGNMENT_ID = "assessment-lens-alignment"

  # @param lens [Assessments::Lens]
  # @param assessment_id [String]
  # @param assessee_name [String, nil] nil for the assessee's own view
  # @param alignment [Assessments::Disclosure::Alignment, nil] alignment
  #   started against the lens role, if any
  # @param can_start_alignment [Boolean] the viewer may start it
  def initialize(lens:, assessment_id:, assessee_name: nil, alignment: nil, can_start_alignment: false)
    @lens = lens
    @assessment_id = assessment_id
    @first_name = assessee_name.to_s.split.first
    @alignment = alignment
    @can_start_alignment = can_start_alignment
  end

  def view_template
    p(id: ID, class: "mt-1 text-sm text-gray-700 dark:text-gray-200") do
      plain "Viewing #{whose} ratings against "
      strong(class: "font-semibold text-gray-900 dark:text-white") { @lens.label }
      plain ". #{whose.capitalize} #{@lens.home_code} assessment is unchanged. "
      a(href: assessment_path(@assessment_id),
        class: "font-medium text-primary hover:underline whitespace-nowrap rounded-sm " \
               "focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-primary") do
        "← Back to #{@lens.home_code}"
      end
    end
    alignment_line
  end

  private

  def alignment_line
    return if @lens.home_role?
    return unless @alignment || manager_side?

    div(id: ALIGNMENT_ID, class: "mt-1 flex flex-wrap items-center gap-x-3 gap-y-1 text-sm " \
                                 "text-gray-600 dark:text-gray-300") do
      span { alignment_text }
      start_trigger if @can_start_alignment && @alignment.nil?
    end
  end

  def alignment_text
    code = @lens.code
    if @alignment&.aligned?
      "Alignment against #{code} is complete."
    elsif @alignment && manager_side?
      "Aligning with #{@first_name} against #{code} — your ratings on its capabilities are shared and locked."
    elsif @alignment
      "Your manager started alignment against #{code} — their ratings on its capabilities are shared with you."
    else
      "Your ratings here are private until you start alignment against #{code}."
    end
  end

  def start_trigger
    button(
      type: "button",
      data: { action: "click->modal#open", modal_target_id: Views::Assessments::StartLensAlignmentModal::ID },
      class: "text-sm font-medium px-3 py-1.5 rounded-md border border-gray-300 dark:border-gray-600 " \
             "text-gray-700 dark:text-gray-200 bg-white dark:bg-gray-800 hover:bg-gray-50 " \
             "dark:hover:bg-gray-700 cursor-pointer focus-visible:outline-hidden focus-visible:ring-2 " \
             "focus-visible:ring-primary"
    ) { "Start alignment against #{@lens.code}" }
  end

  def manager_side?
    @first_name.present?
  end

  def whose
    @first_name.present? ? "#{@first_name}'s" : "your"
  end
end
