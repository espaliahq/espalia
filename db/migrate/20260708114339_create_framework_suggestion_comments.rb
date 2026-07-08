# frozen_string_literal: true

# Discussion-thread comments on framework suggestions, projected from
# SuggestionCommented / SuggestionCommentEdited / SuggestionCommentDeleted
# by Frameworks::Projections::SuggestionThread. The PK is the event-carried
# comment_id, so rebuilds reproduce the same externally-addressable ids.
class CreateFrameworkSuggestionComments < ActiveRecord::Migration[8.1]
  def change
    create_table :framework_suggestion_comments, id: :uuid, default: nil do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.uuid :framework_id, null: false
      t.uuid :suggestion_id, null: false
      t.uuid :parent_id
      t.uuid :author_id, null: false
      t.text :body, null: false
      t.string :status, null: false, default: "active"
      t.datetime :posted_at, null: false
      t.datetime :edited_at
      t.uuid :edited_by_id
      t.datetime :deleted_at
      t.uuid :deleted_by_id
      t.text :deletion_reason
      t.timestamps
    end

    add_index :framework_suggestion_comments, [ :suggestion_id, :status ],
              name: "idx_fw_suggestion_comments_thread"
    add_index :framework_suggestion_comments, [ :framework_id, :status ],
              name: "idx_fw_suggestion_comments_framework"
    add_index :framework_suggestion_comments, :parent_id,
              where: "parent_id IS NOT NULL",
              name: "idx_fw_suggestion_comments_parent"
    add_foreign_key :framework_suggestion_comments, :people,
                    column: :author_id, on_delete: :restrict
  end
end
