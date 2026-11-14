# frozen_string_literal: true

ForgottenPersonAudit.walk("org_graph_as_of") { { date: Date.current.iso8601, mode: "full" } }
