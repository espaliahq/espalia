# frozen_string_literal: true

# Helpers the Feedback / Evidence page's pieces share: who a message is from
# in the viewer's words, avatars, short dates, thread links and the triggers
# that open the evidence modal.
module Views::Evidence::ConversationChrome
  # "You" for the viewer, else the person's first name.
  def who(person_id, person)
    person_id == @viewer_id ? "You" : first_name(person)
  end

  # "you" for the viewer, else the person's first name.
  def whom(person_id, person)
    person_id == @viewer_id ? "you" : first_name(person)
  end

  def first_name(person)
    person&.name.to_s.split.first || "A colleague"
  end

  # "About you" / "About Alex".
  def about_label(person_id, person)
    person_id == @viewer_id ? "About you" : "About #{first_name(person)}"
  end

  def avatar(person, size: :md)
    box = size == :sm ? "size-8 text-xs" : "size-10 text-sm"
    if person&.id == @viewer_id
      span(class: "#{box} shrink-0 rounded-full grid place-items-center font-bold bg-neutral-muted text-default",
           aria: { hidden: "true" }) { "You" }
    else
      initials = person&.name.to_s.split.first(2).map { |w| w[0] }.join.upcase.presence || "?"
      span(class: "#{box} shrink-0 rounded-full grid place-items-center font-semibold bg-neutral-subtle text-default",
           aria: { hidden: "true" }) { initials }
    end
  end

  # "Today", or "3 Nov" (with the year once it isn't this year).
  def short_date(time)
    return "" if time.nil?
    return "Today" if time.to_date == Time.zone.today

    time.year == Time.zone.today.year ? time.strftime("%-d %b") : time.strftime("%-d %b %Y")
  end

  # The thread for one person in a group.
  def conversation_href(person_id, group, **params)
    if group == "report"
      evidence_report_conversation_path(person_id, **params)
    else
      evidence_conversation_path(person_id, **params)
    end
  end

  # Opens the unified evidence modal for a request, an item or a recipient.
  def modal_trigger_data(mode:, request_id: nil, evidence_id: nil, assignment_id: nil)
    data = {
      action: "evidence-modal#load click->modal#open",
      modal_target_id: "evidence-modal-overlay",
      evidence_modal_mode_param: mode,
      evidence_modal_return_to_param: "hub"
    }
    data[:evidence_modal_request_id_param] = request_id if request_id
    data[:evidence_modal_evidence_id_param] = evidence_id if evidence_id
    data[:evidence_modal_assignment_id_param] = assignment_id if assignment_id
    data
  end
end
