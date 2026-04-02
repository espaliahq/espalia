# frozen_string_literal: true

# Typed configuration for HRIS integration stored in Tenant.hris_config JSONB.
#
# Contains non-sensitive settings: provider selection, field mappings,
# role/level mappings, sync toggles, and timestamps. Credentials are stored
# separately in the encrypted `hris_credentials` column.
#
# @example
#   tenant.hris_config.provider        # => "hibob"
#   tenant.hris_config.sync_enabled?   # => true
#   tenant.hris_config.configured?(tenant) # => true
#
class HrisConfig
  include StoreModel::Model

  PROVIDERS = %w[hibob bamboohr].freeze

  attribute :provider, :string
  attribute :field_mappings, HrisFieldMapping.to_array_type, default: -> { [] }
  attribute :role_level_mappings, default: -> { [] }
  attribute :sync_enabled, :boolean, default: false
  attribute :last_synced_at, :datetime
  attribute :webhook_secret, :string

  validates :provider, inclusion: { in: PROVIDERS }, allow_blank: true

  # Returns whether this HRIS config is fully configured and ready to sync.
  #
  # Checks that a provider is set, sync is enabled, and the parent tenant
  # has credentials stored in the encrypted column.
  #
  # @param tenant [Tenant] the parent tenant to check credentials on
  # @return [Boolean]
  def configured?(tenant)
    provider.present? &&
      sync_enabled? &&
      tenant.hris_credentials.present?
  end
end
