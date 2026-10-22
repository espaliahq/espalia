# frozen_string_literal: true

# Settings and credentials for the feedback exchange with a peer system.
# Mirrors the HRIS pair: a typed JSONB config and an encrypted credentials column.
class AddFeedbackExchangeToTenants < ActiveRecord::Migration[8.1]
  def change
    add_column :tenants, :feedback_exchange_config, :jsonb, default: {}, null: false
    add_column :tenants, :feedback_exchange_credentials, :string
  end
end
