# frozen_string_literal: true

# Read models for the "assessment authority" projection
# ({PersonDevelopment::Projections::AssessmentAuthority}):
#
# * `recorded_reporting_managers` — the reporting manager captured on the
#   PersonDevelopment stream (per person, per framework), the authoritative
#   source for "who may manager-rate".
# * `manager_assessment_delegations` — grants of manager-rating authority to
#   another person for one report on one framework.
class CreateAssessmentAuthorityReadModels < ActiveRecord::Migration[8.1]
  def change
    create_table :recorded_reporting_managers, id: :uuid, default: nil do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.uuid :person_id, null: false
      t.uuid :framework_id, null: false
      t.uuid :manager_id, null: false
      t.string :source, null: false, default: "hris"
      t.timestamps
    end
    add_index :recorded_reporting_managers, [ :tenant_id, :person_id, :framework_id ],
              unique: true, name: "idx_recorded_reporting_managers_unique"

    create_table :manager_assessment_delegations, id: :uuid, default: nil do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.uuid :person_id, null: false
      t.uuid :framework_id, null: false
      t.uuid :delegate_person_id, null: false
      t.uuid :granted_by_id, null: false
      t.uuid :revoked_by_id
      t.string :status, null: false, default: "active"
      t.string :reason
      t.datetime :expires_at
      t.datetime :revoked_at
      t.timestamps
    end
    add_index :manager_assessment_delegations,
              [ :tenant_id, :person_id, :framework_id, :delegate_person_id ],
              unique: true, name: "idx_manager_assessment_delegations_unique"
    add_index :manager_assessment_delegations, [ :tenant_id, :delegate_person_id ],
              name: "idx_manager_assessment_delegations_on_delegate"
  end
end
