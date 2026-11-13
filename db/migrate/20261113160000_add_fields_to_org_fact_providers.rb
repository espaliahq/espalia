# frozen_string_literal: true

class AddFieldsToOrgFactProviders < ActiveRecord::Migration[8.1]
  def change
    add_column :org_fact_providers, :fields, :jsonb, default: {}, null: false
  end
end
