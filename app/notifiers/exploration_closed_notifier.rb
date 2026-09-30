# frozen_string_literal: true

# Tells the other party a declared exploration closed, and what came of it
# (ADR-22) — "Morgan closed the exploration of Product Manager · PM3: not
# now". `params[:url]` opens the assessment read through that role and level.
class ExplorationClosedNotifier < ApplicationNotifier
  notifies :exploration_closed

  OUTCOMES = { "pursue" => "pursuing it", "not_now" => "not now", "moved" => "moved into the role" }.freeze

  notification_methods do
    def inbox_title
      actor = params[:actor_name].presence || "Someone"
      outcome = ExplorationClosedNotifier::OUTCOMES[params[:outcome]]
      base = "#{actor} closed the exploration of #{params[:role_label]}"
      outcome ? "#{base}: #{outcome}" : base
    end

    def inbox_body
      quoted_excerpt(params[:note])
    end
  end
end
