# frozen_string_literal: true

class AddFeedbackDirectionToEvidenceItems < ActiveRecord::Migration[8.1]
  def change
    add_column :evidence_items, :feedback_direction, :string
  end
end
