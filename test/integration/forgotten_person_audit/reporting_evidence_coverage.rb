# frozen_string_literal: true

ForgottenPersonAudit.walk("reporting_evidence_coverage") { { **cycle, mode: "full" } }
