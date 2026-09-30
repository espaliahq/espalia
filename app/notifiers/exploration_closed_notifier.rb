# frozen_string_literal: true

# Tells the other party a declared exploration closed, and what came of it
# (ADR-22) — "Morgan closed the exploration of Product Manager · PM3: not
# now". `params[:url]` opens the assessment read through that role and level.
class ExplorationClosedNotifier < ApplicationNotifier
  notifies :exploration_closed

  notification_methods do
    def inbox_title
      actor = params[:actor_name].presence
      outcome = AssessmentExploration::OUTCOME_PHRASES[params[:outcome]]
      base = actor ? "#{actor} closed the exploration of #{params[:role_label]}" : "The exploration of #{params[:role_label]} closed"
      outcome ? "#{base}: #{outcome}" : base
    end

    def inbox_body
      quoted_excerpt(params[:note])
    end
  end
end
