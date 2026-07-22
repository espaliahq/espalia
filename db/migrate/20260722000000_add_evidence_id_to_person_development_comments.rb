# frozen_string_literal: true

class AddEvidenceIdToPersonDevelopmentComments < ActiveRecord::Migration[8.1]
  def change
    # Anchor for commentable_type "evidence_link": the discussion thread on
    # one (evidence_id, capability_stable_id, level_ordinal) linkage of an
    # evidence item. Nullable — assessment_cell comments leave it blank.
    add_column :person_development_comments, :evidence_id, :uuid

    add_index :person_development_comments,
              [ :evidence_id, :capability_stable_id, :level_ordinal ],
              where: "evidence_id IS NOT NULL",
              name: "idx_pdc_evidence_link_anchor"
  end
end
