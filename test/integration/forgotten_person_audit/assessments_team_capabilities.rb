# frozen_string_literal: true

ForgottenPersonAudit.walk("assessments_team_capabilities") { { people: "below", ratings: "self" } }
