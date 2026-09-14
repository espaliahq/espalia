# frozen_string_literal: true

# Saves the migration mappings for every retiring capability in one go — the
# publish-review screen's single "Save mappings" submit (#399), and the same
# thing for an agent that has decided all of them at once.
#
# One aggregate load and one event-store append for the whole set
# ({Frameworks::CommandHandler#batch}), so the save is atomic: a refused row
# leaves nothing half-applied. Rows are triaged before anything is written:
#
# * a row whose type and survivor match what is already recorded is
#   **skipped** — re-defining it would only append a no-op event;
# * a row with no `mapping_type` is **undecided** and left alone;
# * a row whose type needs a survivor but names none is **incomplete** — left
#   unsaved and reported by capability name so the caller can finish it;
# * everything else is saved through the same rules as
#   {Operations::Frameworks::DefineMigrationMapping} (which stays the
#   single-mapping tool for as-we-go archives).
#
# Write — :mcp_client. Restricted to owner/editor
# (FrameworkPolicy#define_migration_mapping?).
class Operations::Frameworks::DefineMigrationMappings < Operations::Base
  description "Save migration mappings for several retiring capabilities in one atomic write; " \
              "unchanged rows are skipped and rows still needing a survivor are reported (owner/editor only)."
  category :write
  approval :mcp_client

  SINGLE = Operations::Frameworks::DefineMigrationMapping

  parameter :framework_id, String, required: true
  parameter :mappings, Array, required: true, schema: {
    type: "array",
    items: {
      type: "object",
      properties: {
        from_stable_id: { type: "string" },
        mapping_type: { type: "string", enum: SINGLE::MAPPING_TYPES },
        to_stable_id: { type: "string" },
        mapping_id: { type: "string" }
      },
      required: %w[from_stable_id]
    }
  }

  def policy_check
    authorize framework, :define_migration_mapping?
  end

  # @return [Hash] { framework_id:, saved: Integer, skipped: Integer, incomplete: Array<String> }
  # @raise [ParameterError] when a row breaks a mapping rule
  def perform
    rows = params[:mappings].map { |row| row.to_h.symbolize_keys }
    rows.each { |row| validate_row!(row) }

    to_save = rows.reject { |row| undecided?(row) || unchanged?(row) || incomplete?(row) }
    incomplete = rows.select { |row| incomplete?(row) }

    Frameworks::CommandHandler.new.batch(framework.framework_id) do
      to_save.each { |row| define(row) }
    end if to_save.any?

    {
      framework_id: framework.framework_id,
      saved: to_save.size,
      skipped: rows.size - to_save.size - incomplete.size,
      incomplete: incomplete.map { |row| capability_names[row[:from_stable_id]] || "a capability" }
    }
  end

  private

  def framework
    @framework ||= FrameworkState::Framework.find_by!(framework_id: params[:framework_id])
  end

  def validate_row!(row)
    raise ParameterError, "each mapping needs a from_stable_id" if row[:from_stable_id].blank?
    if row[:mapping_id].present? && (owner = persisted_by_id[row[:mapping_id]]) && owner.from_stable_id != row[:from_stable_id]
      raise ParameterError, "mapping_id #{row[:mapping_id]} belongs to a different capability"
    end
    return if undecided?(row)

    unless SINGLE::MAPPING_TYPES.include?(row[:mapping_type])
      raise ParameterError, "mapping_type must be one of #{SINGLE::MAPPING_TYPES.inspect}, got #{row[:mapping_type].inspect}"
    end
    if row[:to_stable_id].present? && !survivor_required?(row)
      raise ParameterError, SINGLE::SURVIVOR_FORBIDDEN_MESSAGE.call(row[:mapping_type])
    end
    if row[:to_stable_id].present? && row[:to_stable_id] == row[:from_stable_id]
      raise ParameterError, "a capability cannot be its own survivor (to_stable_id must differ from from_stable_id)"
    end
  end

  def undecided?(row) = row[:mapping_type].blank?

  def survivor_required?(row) = SINGLE::SURVIVOR_TYPES.include?(row[:mapping_type])

  def incomplete?(row) = survivor_required?(row) && row[:to_stable_id].blank?

  def unchanged?(row)
    existing = existing_for(row)
    existing.present? &&
      existing.mapping_type == row[:mapping_type] &&
      existing.to_stable_id == row[:to_stable_id].presence
  end

  # The persisted mapping this row edits: by mapping_id when given, else the
  # one already recorded for the same retiring capability — a retiring
  # capability has one mapping, so an omitted id must edit, not duplicate.
  def existing_for(row)
    (row[:mapping_id].present? && persisted_by_id[row[:mapping_id]]) || persisted_by_source[row[:from_stable_id]]
  end

  def define(row)
    Frameworks::CommandHandler.new.define_migration_mapping(
      framework.framework_id,
      existing_for(row)&.mapping_id || SecureRandom.uuid_v7,
      row[:from_stable_id],
      row[:to_stable_id].presence,
      row[:mapping_type],
      requires_reassessment: SINGLE::REASSESS_TYPES.include?(row[:mapping_type]),
      reason: nil
    )
  end

  def persisted
    @persisted ||= FrameworkState::MigrationMapping.for_draft(framework).to_a
  end

  def persisted_by_id = @persisted_by_id ||= persisted.index_by(&:mapping_id)

  def persisted_by_source = @persisted_by_source ||= persisted.index_by(&:from_stable_id)

  # Retiring capabilities pre-date the draft, so their names are in the
  # published read model.
  def capability_names
    @capability_names ||= FrameworkState::Capability
      .where(stable_id: params[:mappings].map { |row| row.to_h.symbolize_keys[:from_stable_id] })
      .pluck(:stable_id, :name).to_h
  end
end
