# frozen_string_literal: true

# Notifies a comment's author that someone replied to their comment on an
# assessment discussion (a cell thread or an evidence-linkage thread). The
# reply body rides along (quoted, excerpted) with a context line locating the
# conversation; `params[:url]` deep-links to the assessment cell.
class CommentReplyNotifier < ApplicationNotifier
  notifies :comment_reply

  notification_methods do
    def inbox_title
      "#{params[:author_name].presence || "A colleague"} replied to your comment"
    end

    def inbox_body
      labeled_excerpt(params[:context], params[:body])
    end
  end
end
