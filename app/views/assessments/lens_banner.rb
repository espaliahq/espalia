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
#
# Looking through a lens tells nobody; declaring it an exploration is what
# the other party sees. So the last line either names the open exploration
# of the lens role — who started it, when, with a way to stop — or offers to
# declare one: "Keep exploring this" to the assessee, "Share with Alex" to
# the manager side.
class Views::Assessments::LensBanner < Views::Base
  ID = "assessment-lens-banner"
  ALIGNMENT_ID = "assessment-lens-alignment"
  EXPLORATION_ID = "assessment-lens-exploration"
  BUTTON = "text-sm font-medium px-3 py-1.5 rounded-md border border-gray-300 dark:border-gray-600 " \
           "text-gray-700 dark:text-gray-200 bg-white dark:bg-gray-800 hover:bg-gray-50 " \
           "dark:hover:bg-gray-700 cursor-pointer focus-visible:outline-hidden focus-visible:ring-2 " \
           "focus-visible:ring-primary"

  # @param lens [Assessments::Lens]
  # @param assessment_id [String]
  # @param assessee_name [String, nil] nil for the assessee's own view
  # @param alignment [Assessments::Disclosure::Alignment, nil] alignment
  #   started against the lens role, if any
  # @param can_start_alignment [Boolean] the viewer may start it
  # @param viewer [Symbol] :assessee, :manager (the reporting manager),
  #   :delegate (an active rating delegate) or :observer (anyone else who
  #   may look) — whose ratings "your ratings" would be
  # @param exploration [AssessmentExploration, nil] the open exploration of
  #   the lens role, `started_by` preloaded
  # @param can_explore [Boolean] the viewer may declare or close one
  # @param viewer_person_id [String, nil] to say "started by you"
  def initialize(lens:, assessment_id:, assessee_name: nil, alignment: nil, can_start_alignment: false,
                 viewer: nil, exploration: nil, can_explore: false, viewer_person_id: nil)
    @exploration = exploration
    @can_explore = can_explore
    @viewer_person_id = viewer_person_id
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
    exploration_line
  end

  private

  def exploration_line
    return if @lens.home?
    return unless @exploration || @can_explore

    div(id: EXPLORATION_ID, class: "mt-1 flex flex-wrap items-center gap-x-3 gap-y-1 text-sm " \
                                   "text-gray-600 dark:text-gray-300") do
      if @exploration
        open_exploration
      else
        span { @first_name ? "#{@first_name} isn't told you're looking." : "Nobody is told you're looking." }
        modal_trigger(Views::Assessments::StartExplorationModal::ID,
                      @first_name ? "Share with #{@first_name}" : "Keep exploring this")
      end
    end
  end

  def open_exploration
    span(data: { exploration: @exploration.code }) do
      plain "Exploring "
      strong(class: "font-semibold text-gray-900 dark:text-white") { @exploration.code }
      plain " since #{@exploration.started_at.strftime("%-d %b")} · started by #{starter}"
    end
    if @exploration.start_note.present?
      span(class: "italic text-gray-500 dark:text-gray-400 line-clamp-2") { "“#{@exploration.start_note}”" }
    end
    modal_trigger(Views::Assessments::StopExplorationModal::ID, "Stop exploring") if @can_explore
  end

  def starter
    return "you" if @exploration.started_by_id.present? && @exploration.started_by_id == @viewer_person_id

    @exploration.started_by&.name.to_s.split.first.presence || "someone"
  end

  def modal_trigger(modal_id, text)
    button(type: "button", data: { action: "click->modal#open", modal_target_id: modal_id }, class: BUTTON) { text }
  end

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
    modal_trigger(Views::Assessments::StartLensAlignmentModal::ID, "Start alignment against #{@lens.code}")
  end

  def whose
    @first_name.present? ? "#{@first_name}'s" : "your"
  end
end
