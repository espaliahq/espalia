# frozen_string_literal: true

ForgottenPersonAudit.walk("org_graph_activity") { { unit_id: @unit_id } }
