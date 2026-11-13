# frozen_string_literal: true

namespace :org_graph do
  desc "Hand each configured HRIS the person facts it supplies by default. Safe to re-run; predeploy runs it."
  task claim_hris_facts: :environment do
    AuditMetadata.with(acting_via: :system) do
      AuditMetadata.wrap_event_store do
        Tenant.find_each do |tenant|
          next unless tenant.hris_config.configured?(tenant)

          claimed = tenant.claim_hris_facts!
          puts "[#{tenant.id}] #{claimed.any? ? "claimed #{claimed.join(", ")}" : "nothing new to claim"}"
        end
      end
    end
  end
end
