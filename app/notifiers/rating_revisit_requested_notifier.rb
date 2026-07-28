# frozen_string_literal: true

# Notifies a rater that a calibration session asked them to revisit one of
# their manager ratings. Value-free by design — the body carries the room's
# discussion note (quoted, excerpted) with a context line locating the cell
# and naming the session; `params[:url]` deep-links to the assessment cell
# (the manager view for the rater).
class RatingRevisitRequestedNotifier < ApplicationNotifier
  notifies :rating_revisit_requested

  notification_methods do
    def inbox_title
      asker = params[:requested_by_name].presence || "A calibration session"
      assessee = params[:assessee_name].presence
      assessee ? "#{asker} asked you to revisit #{assessee}'s rating" : "#{asker} asked you to revisit a rating"
    end

    def inbox_body
      labeled_excerpt(params[:context], params[:note])
    end
  end
end
