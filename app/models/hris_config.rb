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
  attribute :role_mappings, HrisRoleMapping.to_array_type, default: -> { [] }
  attribute :level_field_id, :string
  attribute :sync_enabled, :boolean, default: false
  attribute :last_synced_at, :datetime
  attribute :webhook_secret, :string

  validates :provider, inclusion: { in: PROVIDERS }, allow_blank: true
  validate :role_mappings_have_unique_titles

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

  # The mapping a title resolves to, or nil when no mapping lists it.
  #
  # @param title [String, nil]
  # @return [HrisRoleMapping, nil]
  def mapping_for(title)
    title_lookup[HrisRoleMapping.normalize_title(title)]
  end

  # Normalized title → mapping, for resolving many people in one pass.
  #
  # @return [Hash{String => HrisRoleMapping}]
  def title_lookup
    Array(role_mappings).each_with_object({}) do |mapping, lookup|
      mapping.normalized_hris_titles.each { |title| lookup[title] = mapping }
    end
  end

  # Maps one HRIS title to a framework role, taking it out of whichever
  # mapping held it before.
  #
  # Titles are grouped by (role code, level ordinal) on write, so the stored
  # shape stays the one the sync has always read, and a title can never sit
  # in two mappings at once.
  #
  # @param title [String]
  # @param framework_role_code [String]
  # @param level_ordinal [Integer, nil] nil reads the level from the HRIS
  #   level column (see {#level_field_id})
  # @return [Array<HrisRoleMapping>] the new role_mappings
  def map_title(title, framework_role_code:, level_ordinal: nil)
    title = title.to_s.strip
    mappings = mappings_without(title)
    group = mappings.find do |mapping|
      mapping.framework_role_code == framework_role_code && mapping.level_ordinal == level_ordinal
    end

    if group
      group.hris_titles = Array(group.hris_titles) + [ title ]
    else
      mappings << HrisRoleMapping.new(
        hris_titles: [ title ], framework_role_code: framework_role_code, level_ordinal: level_ordinal
      )
    end
    self.role_mappings = mappings
  end

  # Removes one HRIS title, dropping a mapping it leaves empty.
  #
  # @param title [String]
  # @return [Array<HrisRoleMapping>] the new role_mappings
  def unmap_title(title)
    self.role_mappings = mappings_without(title)
  end

  private

  # Fresh copies of every mapping with `title` removed, empty ones dropped.
  def mappings_without(title)
    normalized = HrisRoleMapping.normalize_title(title)

    Array(role_mappings).filter_map do |mapping|
      kept = Array(mapping.hris_titles).reject { |t| HrisRoleMapping.normalize_title(t) == normalized }
      next if kept.empty?

      HrisRoleMapping.new(
        hris_titles: kept,
        framework_role_code: mapping.framework_role_code,
        level_ordinal: mapping.level_ordinal
      )
    end
  end

  # Ensures no two role_mappings entries share a normalized HRIS title.
  def role_mappings_have_unique_titles
    seen = {}
    Array(role_mappings).each_with_index do |mapping, idx|
      mapping.normalized_hris_titles.each do |title|
        if seen.key?(title)
          errors.add(:role_mappings, "title '#{title}' appears in multiple mappings (entries #{seen[title]} and #{idx})")
        else
          seen[title] = idx
        end
      end
    end
  end
end
