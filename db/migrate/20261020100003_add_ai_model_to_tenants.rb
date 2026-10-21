# frozen_string_literal: true

# The model behind AI features, chosen per tenant: a typed JSONB config and an
# encrypted credentials column, the same pair HRIS uses.
class AddAiModelToTenants < ActiveRecord::Migration[8.1]
  def change
    add_column :tenants, :ai_config, :jsonb, default: {}, null: false
    add_column :tenants, :ai_credentials, :string
  end
end
