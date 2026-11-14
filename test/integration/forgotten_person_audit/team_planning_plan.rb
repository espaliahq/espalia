# frozen_string_literal: true

ForgottenPersonAudit.walk("team_planning_plan") { { plan_id: @plan_id } }
