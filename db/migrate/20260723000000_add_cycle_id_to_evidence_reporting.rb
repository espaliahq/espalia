# frozen_string_literal: true

class AddCycleIdToEvidenceReporting < ActiveRecord::Migration[8.1]
  def change
    add_column :evidence_items, :cycle_id, :uuid
    add_column :evidence_requests, :cycle_id, :uuid

    add_index :evidence_items, %i[tenant_id cycle_id person_id],
              name: "idx_evidence_items_tenant_cycle_person"
    add_index :evidence_requests, %i[tenant_id cycle_id person_id],
              name: "idx_evidence_requests_tenant_cycle_person"
  end
end
