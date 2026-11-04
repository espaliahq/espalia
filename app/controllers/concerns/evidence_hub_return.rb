# frozen_string_literal: true

# Where a write started on the Feedback / Evidence page lands afterwards: back
# on the conversation it came from, with its view (`?place=`, `?view=`), so
# answering one request doesn't drop the reader at the top of the page.
module EvidenceHubReturn
  extend ActiveSupport::Concern

  private

  # @return [String] the hub page the request came from, or the hub itself
  def hub_return_path
    from = URI.parse(request.referer.to_s)
    path = from.path.to_s
    hub_page = path == "/evidence" || (path.start_with?("/evidence/") && !path.start_with?("/evidence/drafts"))
    return evidence_hub_path unless hub_page

    query = Rack::Utils.parse_query(from.query).slice("place", "view").compact_blank
    query.empty? ? from.path : "#{from.path}?#{query.to_query}"
  rescue URI::InvalidURIError
    evidence_hub_path
  end
end
