# frozen_string_literal: true

ForgottenPersonAudit.walk("org_graph_person_get") { { person_id: @quinn.id } }
