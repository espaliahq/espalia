# frozen_string_literal: true

# Tells the admin who started a background bulk enrollment how it ended —
# the flash at enqueue time only promises the eligible count, so without
# this a partial outcome (races, aggregate refusals) would be visible only
# in server logs until someone notices missing participants.
class BulkEnrollmentCompletedNotifier < ApplicationNotifier
  notifies :bulk_enrollment_completed

  notification_methods do
    def inbox_title
      "Enrollment finished for #{params[:cycle_name]}"
    end

    def inbox_body
      body = "Enrolled #{params[:enrolled]} #{"person".pluralize(params[:enrolled])}."
      skipped = Array(params[:skipped_names])
      if skipped.any?
        shown = skipped.first(5).join(", ")
        shown += " and #{skipped.size - 5} more" if skipped.size > 5
        body += " Skipped #{skipped.size}: #{shown}."
      end
      body
    end

    def inbox_url = "/assessment_cycles/#{params[:cycle_row_id]}"
  end
end
