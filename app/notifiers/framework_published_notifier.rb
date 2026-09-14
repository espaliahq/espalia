# frozen_string_literal: true

# Tells the owner/editor who requested a framework publish how it ended. The
# request itself only says "publishing in the background"; the outcome — the
# new live version, or the aggregate's refusal — has to reach them wherever
# they went next, not just the review page.
class FrameworkPublishedNotifier < ApplicationNotifier
  notifies :framework_published

  notification_methods do
    def inbox_title
      if params[:succeeded]
        "#{params[:framework_name]} v#{params[:version]} is live"
      else
        "Publishing #{params[:framework_name]} v#{params[:version]} failed"
      end
    end

    def inbox_body
      if params[:succeeded]
        "The draft was published and in-flight assessments were migrated."
      else
        "Nothing was published. #{params[:error]}"
      end
    end

    def inbox_url = "/frameworks/#{params[:framework_id]}/edit"
  end
end
