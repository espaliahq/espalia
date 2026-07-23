# frozen_string_literal: true

# Notifies the manager side (recorded reporting manager + active rating
# delegates) that their report commented on their own assessment. The comment
# body rides along (quoted, excerpted) with a context line locating the
# conversation; `params[:url]` deep-links to the assessment cell (the same
# path renders the manager view for a manager-side viewer).
class TeamAssessmentCommentedNotifier < ApplicationNotifier
  notifies :team_assessment_commented

  notification_methods do
    def inbox_title
      "#{params[:author_name].presence || "A report"} commented on their assessment"
    end

    def inbox_body
      labeled_excerpt(params[:context], params[:body])
    end
  end
end
