# frozen_string_literal: true

ForgottenPersonAudit.walk("org_graph_stale_facts") { { person_ids: [ @quinn.id ] } }
