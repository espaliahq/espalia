# frozen_string_literal: true

# Notifies the assessee that someone else (their manager, a delegate, an
# admin) commented on their assessment — a cell thread or an evidence-linkage
# thread. The comment body rides along (quoted, excerpted) with a context line
# locating the conversation; `params[:url]` deep-links to the assessment cell.
class AssessmentCommentedNotifier < ApplicationNotifier
  notifies :assessment_commented

  notification_methods do
    def inbox_title
      "#{params[:author_name].presence || "A colleague"} commented on your assessment"
    end

    def inbox_body
      labeled_excerpt(params[:context], params[:body])
    end
  end
end
