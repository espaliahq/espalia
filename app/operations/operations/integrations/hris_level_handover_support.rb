# frozen_string_literal: true

# What the three level handover operations share (#117): finding the level,
# building the handover, turning its refusals into parameter errors, and the
# comparison's payload.
module Operations::Integrations::HrisLevelHandoverSupport
  MAP_SCHEMA = { type: "object", additionalProperties: { type: "string" } }.freeze

  private

  def handover
    tenant = ActsAsTenant.current_tenant
    raise Operations::Base::ParameterError, "No HRIS is connected" unless tenant.hris_config.connected?(tenant)

    level = OrgTaxonomyLevel.find_by(id: params[:level_id].to_s.downcase) or
      raise Operations::Base::ParameterError, "level_id: no structure level has that id"
    Hris::LevelHandover.new(tenant, level)
  end

  def refusals
    yield
  rescue Hris::LevelHandover::Refused => e
    raise Operations::Base::ParameterError, e.message
  rescue Hris::Hibob::Errors::AuthenticationError
    raise Operations::Base::ParameterError, "The HRIS refused the stored credentials."
  rescue Hris::Hibob::Errors::RateLimitError
    raise Operations::Base::ParameterError, "The HRIS is limiting requests just now. Try again in a minute."
  rescue RuntimeError => e
    # The Org Graph aggregates refuse a change with a RuntimeError that says why.
    raise Operations::Base::ParameterError, e.message
  end

  # Counts and labels, and no one's name: the people behind each count are
  # for the settings screen, which reads the comparison itself.
  #
  # @param comparison [Hris::LevelHandover::Comparison]
  # @return [Hash]
  def comparison_payload(comparison)
    {
      direction: "hand_over",
      level: { id: comparison.level.id, name: comparison.level.name },
      field: { id: comparison.field.id, name: comparison.field.name, kind: comparison.field.kind.to_s },
      units: comparison.units.map { |unit| unit_payload(unit, comparison) },
      items: comparison.items,
      people: comparison.preview.except(:readings, :units),
      differing: comparison.differing.size, blank: comparison.blank.size,
      hand_added: comparison.hand_added.size, joining: comparison.joining,
      unresolved: comparison.unresolved,
      brake: { memberships_ended: comparison.memberships_ended, units_retired: comparison.units_retired,
               over: comparison.over_brake? },
      fingerprint: comparison.fingerprint
    }
  end

  def unit_payload(unit, comparison)
    in_unit = ->(rows) { rows.count { it[:unit_id] == unit[:unit_id] } }
    unit.merge(differing: in_unit.(comparison.differing), blank: in_unit.(comparison.blank),
               hand_added: in_unit.(comparison.hand_added))
  end

  # @param handback [Hris::LevelHandover::Handback]
  # @return [Hash]
  def handback_payload(handback)
    { direction: "hand_back", level: { id: handback.level.id, name: handback.level.name }, provider: handback.provider,
      units: handback.units, memberships: handback.memberships, fingerprint: handback.fingerprint }
  end
end
