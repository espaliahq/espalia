# frozen_string_literal: true

# Feedback given from Slack by someone GrowthOS knows from HRIS but who has
# never signed in: the submission is kept here and a link DM'd to them, so
# their first sign-in lands on the hub with the modal already filled. The
# token is the only handle; a draft is bound to the author's email and expires.
class CreateFeedbackDrafts < ActiveRecord::Migration[8.1]
  def change
    create_table :feedback_drafts, id: :uuid, default: nil do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true, index: true
      t.string :token, null: false
      t.string :author_email, null: false
      t.uuid :recipient_person_id
      t.uuid :assignment_id
      t.text :content, null: false
      t.string :evidence_type, null: false
      t.jsonb :external_reference, default: {}, null: false
      t.string :source, null: false, default: "slack"
      t.datetime :expires_at, null: false
      t.datetime :consumed_at
      t.timestamps
    end
    add_index :feedback_drafts, :token, unique: true
  end
end
