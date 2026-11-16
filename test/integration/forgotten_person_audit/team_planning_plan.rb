# frozen_string_literal: true

# The archived plan, so the walk reaches `archived.by_name` as well as the members.
ForgottenPersonAudit.walk("team_planning_plan") { { plan_id: @archived_plan_id } }
