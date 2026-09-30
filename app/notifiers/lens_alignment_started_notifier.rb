# frozen_string_literal: true

# Tells an assessee their manager started alignment against another role
# (ADR-22) — "Morgan started alignment against Product Manager · PM3". The
# conversation lives under a lens the assessee may never open, so this is
# how they learn the manager's ratings there are now shared with them.
# `params[:url]` opens the assessment read through that role.
class LensAlignmentStartedNotifier < ApplicationNotifier
  notifies :lens_alignment_started

  notification_methods do
    def inbox_title
      starter = params[:started_by_name].presence || "Your manager"
      "#{starter} started alignment against #{params[:role_label]}"
    end

    def inbox_body
      "Their ratings on the #{params[:role_code]} capabilities are now shared with you. " \
        "Your #{params[:home_code]} assessment is unchanged."
    end
  end
end
