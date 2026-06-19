# frozen_string_literal: true

# A minimal notifier used by tests to exercise the in-app inbox without
# depending on a concrete domain notifier (those arrive in later phases).
# Bound to the :evidence_requested type so preference gating can be exercised.
class InboxTestNotifier < ApplicationNotifier
  notifies :evidence_requested

  notification_methods do
    def inbox_title = "Test: #{params[:title]}"
    def inbox_body = params[:body]
    def inbox_url = params[:url] || "/"
  end
end
