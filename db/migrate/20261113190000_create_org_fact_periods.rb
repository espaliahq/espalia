# frozen_string_literal: true

# What the Org Graph knew about each fact and when, projected from the person
# and structure streams by OrgGraph::Projections::History. A row says a fact
# held a value from effective_from until effective_to, as known from
# learned_at until superseded_at. A correction supersedes rows and adds new
# ones; it never edits what an earlier row says.
class CreateOrgFactPeriods < ActiveRecord::Migration[8.1]
  def change
    create_table :org_fact_periods, id: :uuid, default: nil do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true, index: false
      t.string :subject_type, null: false
      t.uuid :subject_id, null: false
      t.string :fact, null: false
      t.string :key, null: false, default: ""
      t.jsonb :value
      t.string :provider
      t.date :effective_from, null: false
      t.date :effective_to
      t.datetime :learned_at, null: false
      t.datetime :superseded_at
      t.uuid :event_id, null: false
      t.uuid :learned_by_event_id, null: false
      t.uuid :superseded_by_event_id
    end
    add_index :org_fact_periods, %i[tenant_id subject_type subject_id fact key effective_from],
              unique: true, where: "superseded_at IS NULL", name: "index_org_fact_periods_on_current_knowledge"
    add_index :org_fact_periods, %i[tenant_id subject_type fact learned_at], name: "index_org_fact_periods_for_as_of"
    add_index :org_fact_periods, %i[tenant_id learned_by_event_id]
    add_index :org_fact_periods, %i[tenant_id superseded_by_event_id]
  end
end
