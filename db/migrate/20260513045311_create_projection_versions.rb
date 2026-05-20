# frozen_string_literal: true

class CreateProjectionVersions < ActiveRecord::Migration[8.1]
  def change
    create_table :projection_versions, id: false do |t|
      t.string   :name,       null: false, primary_key: true
      t.integer  :version,    null: false
      t.datetime :applied_at, null: false
    end
  end
end
