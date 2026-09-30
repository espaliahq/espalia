# frozen_string_literal: true

# Tells the other party a declared exploration started (ADR-22): the manager
# side hears "Alex started exploring Product Manager · PM3"; the assessee
# hears "Morgan shared an exploration of Product Manager · PM3 with you",
# and a reporting manager whose delegate shared it hears "… with Alex".
# `params[:url]` opens the assessment read through that role and level.
class ExplorationStartedNotifier < ApplicationNotifier
  notifies :exploration_started

  notification_methods do
    def inbox_title
      actor = params[:actor_name].presence || "Someone"
      if params[:by_assessee]
        "#{actor} started exploring #{params[:role_label]}"
      else
        whom = params[:to_assessee] ? "you" : (params[:assessee_name].presence || "their report")
        "#{actor} shared an exploration of #{params[:role_label]} with #{whom}"
      end
    end

    def inbox_body
      quoted_excerpt(params[:note])
    end
  end
end
