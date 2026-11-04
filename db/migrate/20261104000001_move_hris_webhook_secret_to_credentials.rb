# frozen_string_literal: true

# The HRIS webhook secret sat in the plain `hris_config` JSONB, readable by
# anyone with database access. It is a secret like the API token, so it moves
# into the encrypted `hris_credentials` column.
#
# The config is read as raw JSON (not through HrisConfig, which no longer has
# the attribute); the credentials are written through the model so ActiveRecord
# encryption applies.
class MoveHrisWebhookSecretToCredentials < ActiveRecord::Migration[8.1]
  def up
    Tenant.reset_column_information

    rows = select_all("SELECT id, hris_config->>'webhook_secret' AS secret FROM tenants WHERE hris_config ? 'webhook_secret'")
    rows.each do |row|
      if row["secret"].present?
        begin
          tenant = Tenant.find(row["id"])
          credentials = (tenant.hris_credentials.is_a?(Hash) ? tenant.hris_credentials : {}).dup
          credentials["webhook_secret"] ||= row["secret"]
          tenant.update_columns(hris_credentials: credentials)
        rescue ActiveRecord::Encryption::Errors::Base => e
          # An undecryptable credentials row must not abort the deploy; the
          # secret stays where it was for a human to move.
          say "Skipping tenant #{row['id']}: #{e.class}", true
          next
        end
      end

      execute(<<~SQL)
        UPDATE tenants SET hris_config = hris_config - 'webhook_secret' WHERE id = '#{row['id']}'
      SQL
    end
  end

  def down
    # The secret stays in the encrypted column; nothing to restore.
  end
end
