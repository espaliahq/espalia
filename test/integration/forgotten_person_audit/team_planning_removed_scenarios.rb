# frozen_string_literal: true

ForgottenPersonAudit.walk("team_planning_removed_scenarios") { { plan_id: @plan_id } }
