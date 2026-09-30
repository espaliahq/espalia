# frozen_string_literal: true

# Tells the other party a declared exploration started (ADR-22): the manager
# side hears "Alex started exploring Product Manager · PM3"; the assessee
# hears "Morgan shared an exploration of Product Manager · PM3 with you".
# `params[:url]` opens the assessment read through that role and level.
class ExplorationStartedNotifier < ApplicationNotifier
  notifies :exploration_started

  notification_methods do
    def inbox_title
      actor = params[:actor_name].presence || "Someone"
      if params[:by_assessee]
        "#{actor} started exploring #{params[:role_label]}"
      else
        "#{actor} shared an exploration of #{params[:role_label]} with you"
      end
    end

    def inbox_body
      quoted_excerpt(params[:note])
    end
  end
end
