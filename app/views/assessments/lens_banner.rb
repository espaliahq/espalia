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
  # @param viewer [Symbol] :assessee, :manager (the reporting manager),
  #   :delegate (an active rating delegate) or :observer (anyone else who
  #   may look) — whose ratings "your ratings" would be
  def initialize(lens:, assessment_id:, assessee_name: nil, alignment: nil, can_start_alignment: false,
                 viewer: nil)
    @lens = lens
    @assessment_id = assessment_id
    @first_name = assessee_name.to_s.split.first
    @alignment = alignment
    @can_start_alignment = can_start_alignment
    @viewer = viewer || (assessee_name.present? ? :observer : :assessee)
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
    text = alignment_text
    return unless text

    div(id: ALIGNMENT_ID, class: "mt-1 flex flex-wrap items-center gap-x-3 gap-y-1 text-sm " \
                                 "text-gray-600 dark:text-gray-300") do
      span { text }
      start_trigger if @can_start_alignment && @alignment.nil?
    end
  end

  # Names the conversation's own level, which a lens on another level of the
  # same role doesn't change.
  def alignment_text
    return started_text(@alignment.code) if @alignment

    case @viewer
    when :manager then "Your ratings here are private until you start alignment against #{@lens.code}."
    when :delegate
      "Your ratings here are private until #{@first_name}'s manager starts alignment against #{@lens.code}."
    end
  end

  def started_text(code)
    return "Alignment against #{code} is complete." if @alignment.aligned?

    case @viewer
    when :manager
      "Aligning with #{@first_name} against #{code} — your ratings on its capabilities are shared and locked."
    when :assessee
      "Your manager started alignment against #{code} — their ratings on its capabilities are shared with you."
    else
      "Alignment against #{code} is in progress — manager ratings on its capabilities are shared with #{@first_name}."
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

  def whose
    @first_name.present? ? "#{@first_name}'s" : "your"
  end
end
