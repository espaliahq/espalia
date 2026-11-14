# frozen_string_literal: true

ForgottenPersonAudit.walk("org_graph_changes_between") { { from: 1.month.ago.to_date.iso8601, to: Date.current.iso8601, mode: "full" } }
