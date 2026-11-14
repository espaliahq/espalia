# frozen_string_literal: true

ForgottenPersonAudit.walk("team_planning_drift") { { plan_id: @plan_id } }
