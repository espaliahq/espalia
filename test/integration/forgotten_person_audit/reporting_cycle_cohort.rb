# frozen_string_literal: true

ForgottenPersonAudit.walk("reporting_cycle_cohort") { { **cycle, mode: "full" } }
