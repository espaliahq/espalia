# frozen_string_literal: true

# A request names the secret that signed it by a short key id (the first 16 hex
# characters of its SHA-256), so the verifier loads one tenant instead of trying
# every credentialed one. A key id reveals nothing usable about the secret.
class AddFeedbackExchangeKeyIdsToTenants < ActiveRecord::Migration[8.1]
  def up
    add_column :tenants, :inbound_key_id, :string
    add_column :tenants, :previous_inbound_key_id, :string
    add_index :tenants, :inbound_key_id, where: "inbound_key_id IS NOT NULL"
    add_index :tenants, :previous_inbound_key_id, where: "previous_inbound_key_id IS NOT NULL"

    Tenant.reset_column_information
    Tenant.where.not(feedback_exchange_credentials: nil).find_each do |tenant|
      secrets = tenant.feedback_exchange_secrets
      tenant.update_columns(
        inbound_key_id: secrets.inbound_secret && FeedbackExchange::Signature.key_id(secrets.inbound_secret),
        previous_inbound_key_id: secrets.previous_inbound_secret && FeedbackExchange::Signature.key_id(secrets.previous_inbound_secret)
      )
    end
  end

  def down
    remove_column :tenants, :previous_inbound_key_id
    remove_column :tenants, :inbound_key_id
  end
end
