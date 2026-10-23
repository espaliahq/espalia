# frozen_string_literal: true

# Content for the "Evidence requested of you" card — pending evidence requests
# addressed to the viewer that still need a response. Links to the evidence hub,
# where the full cell context and respond/decline actions live.
class Views::Home::Cards::EvidenceRequests < Views::Base
  PREVIEW_LIMIT = 5

  # @param requests [Array<EvidenceRequest>] pending requests addressed to the viewer
  def initialize(requests:)
    @requests = requests
  end

  def view_template
    render Components::Kit::Card.new(title: "Feedback / Evidence requested of you", heading_level: :h2) do |card|
      card.body do
        summary_line
        request_list
      end
      card.actions { respond_link }
    end
  end

  private

  def summary_line
    count = @requests.size
    p(class: "text-sm text-muted") do
      "#{count} #{count == 1 ? "colleague is" : "colleagues are"} waiting on your feedback."
    end
  end

  def request_list
    return if @requests.empty?

    ul(class: "mt-3 space-y-1") do
      @requests.first(PREVIEW_LIMIT).each do |request|
        li(class: "text-sm text-muted") do
          plain request.requester&.name || "A colleague"
          span(class: "text-muted") { regarding_suffix(request) }
        end
      end
      if @requests.size > PREVIEW_LIMIT
        li(class: "text-sm text-muted") do
          "+#{@requests.size - PREVIEW_LIMIT} more"
        end
      end
    end
  end

  # ", regarding <assessee>" when a manager asked on a report's behalf; blank
  # when the requester is asking about their own assessment. Mirrors the hub.
  def regarding_suffix(request)
    return "" if request.person_id == request.requested_by_id

    name = request.assessee&.name
    name.present? ? " · regarding #{name}" : ""
  end

  def respond_link
    a(
      href: evidence_hub_path,
      data: { turbo_frame: "_top" },
      class: "inline-flex items-center min-h-11 text-sm font-medium text-brand hover:underline"
    ) { "Respond →" }
    a(
      href: evidence_hub_path(give: 1),
      data: { turbo_frame: "_top" },
      class: "inline-flex items-center min-h-11 ml-4 text-sm font-medium text-brand hover:underline"
    ) { "Give feedback →" }
  end
end
