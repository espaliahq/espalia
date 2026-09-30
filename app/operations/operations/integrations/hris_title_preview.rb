# frozen_string_literal: true

# Describes what the next HRIS sync will do to the people holding one title —
# the shared payload shape of the three HRIS title operations.
module Operations::Integrations::HrisTitlePreview
  private

  # @param rows [Array<Integrations::HrisPersonRow>]
  # @return [Array<Hash>]
  def people_payload(rows)
    rows.map do |row|
      {
        person_id: row.person.id,
        name: row.person.name,
        hris_level: row.person.hris_level_ordinal,
        current_assignment: row.assignment ? row.assigned_label : nil,
        next_sync_assignment: row.target_label,
        status: row.status.to_s
      }
    end
  end

  # @param mapping [HrisRoleMapping, nil]
  # @return [Hash, nil]
  def mapping_payload(mapping)
    return nil if mapping.nil?

    {
      framework_role_code: mapping.framework_role_code,
      level_ordinal: mapping.level_ordinal,
      level_source: mapping.level_ordinal ? "fixed" : "hris_level_column"
    }
  end

  # Active HRIS people currently holding `title`, resolved against the
  # tenant's mappings as they stand now.
  #
  # @return [Array<Integrations::HrisPersonRow>]
  def rows_for_title(tenant, title)
    normalized = HrisRoleMapping.normalize_title(title)
    Integrations::HrisTitleResolution.new(tenant).titles
      .find { |entry| HrisRoleMapping.normalize_title(entry.title) == normalized }&.rows || []
  end
end
