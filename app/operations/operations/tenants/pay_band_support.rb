# frozen_string_literal: true

# What the pay band tools share: the admin-only check, reading a figure, and
# the payload each returns. A refusal never repeats a figure, so a band can't
# reach a log through an error message.
#
# Admins only, so even an Org Graph editor is refused
# [#191](https://github.com/espaliahq/espalia/issues/191). A band matches on
# whichever of role family, role, level number and country it sets, and the
# bands form an ordered list where the last match wins
# [#368](https://github.com/espaliahq/espalia/issues/368).
module Operations::Tenants::PayBandSupport
  include Operations::Tenants::EditorNames
  include Operations::Tenants::PlanningInputWrites

  MATCHER_PARAMS = %i[role_family_id role_id level_ordinal level_id].freeze
  MATCHER_HELP = "A band matches on whichever of role_family_id, role_id (both from frameworks_get), level_ordinal " \
                 "(the level number, 1 for a role's first level) and location it is given; one left out matches " \
                 "anything. Give a role or a role family, not both. level_id instead matches one framework level, " \
                 "follows it when the framework renumbers it, and keeps pricing its seats once it leaves. " \
                 "The bands form an ordered list: of the bands that match a seat, the last has the last word. A " \
                 "new band lands after the last band no narrower than it; tenants_reorder_pay_bands moves it."
  FIGURE = /\A\d{1,12}(\.\d{1,2})?\z/
  FIGURE_SCHEMA = { type: "string", pattern: FIGURE.source.sub("\\A", "^").sub("\\z", "$") }.freeze
  FIGURE_HELP = "Figures are decimal strings with at most two decimal places, such as \"120000\"."

  # Declares the matcher fields, and the pairs a band can't match on together.
  #
  # @param operation [Class<Operations::Base>]
  def self.declare_matcher(operation)
    operation.parameter :role_family_id, String
    operation.parameter :role_id, String
    operation.parameter :level_ordinal, Integer, schema: { type: "integer", minimum: 1 }
    operation.parameter :level_id, String
    operation.excludes :role_id, :role_family_id,
                       message: "A band matches on a role or a role family, not both: a role already names its family"
    operation.excludes :level_id, :role_id, :role_family_id, :level_ordinal,
                       message: "Give level_id, or a role or role family and a level number, not both"
  end

  # @raise [Pundit::NotAuthorizedError] unless the caller is a tenant admin
  def policy_check
    authorize ActsAsTenant.current_tenant, :manage_pay_bands?, policy_class: TenantPolicy
  end

  private

  # A blank field counts, so a call can clear every field and widen a band to
  # every role and level.
  #
  # @return [Boolean] whether the call says what the band matches on
  def matcher_given? = MATCHER_PARAMS.any? { !params[it].nil? }

  # Sets what the band matches on from the call's matcher fields.
  #
  # @param band [PayBand]
  # @raise [Operations::Base::ParameterError] for an id the framework doesn't hold, or a level number below 1
  def match!(band)
    return band.take_names_from(find_in_framework(FrameworkState::Level, :level_id, "level")) if params[:level_id].present?

    ordinal = params[:level_ordinal]
    raise Operations::Base::ParameterError, "level_ordinal must be 1 or more" if ordinal && ordinal < 1

    band.match_on(role: params[:role_id].presence && find_in_framework(FrameworkState::Role, :role_id, "role"),
                  role_family: params[:role_family_id].presence && find_in_framework(FrameworkState::RoleFamily, :role_family_id, "role family"),
                  level_ordinal: ordinal)
  end

  def find_in_framework(model, key, noun)
    model.find_by(key => params[key].to_s.downcase) || raise(Operations::Base::ParameterError, "There is no such #{noun} in the framework")
  end

  # @return [Hash{Symbol => BigDecimal}] minimum, midpoint and maximum
  def figures
    PayBand::FIGURES.index_with do |name|
      value = params[name].to_s.strip
      raise Operations::Base::ParameterError, "#{name} must be a number with at most two decimal places" unless value.match?(FIGURE)

      BigDecimal(value)
    end
  end

  # What the bands match on as the framework has it now, for naming them.
  #
  # @param bands [Array<PayBand>]
  # @return [Hash{Symbol => Hash}] levels, roles and families by id
  def framework_for(bands)
    levels = FrameworkState::Level.where(level_id: bands.filter_map(&:level_id)).index_by(&:level_id)
    roles = FrameworkState::Role.where(role_id: bands.filter_map(&:role_id) | levels.values.map(&:role_id)).index_by(&:role_id)
    families = FrameworkState::RoleFamily.where(role_family_id: bands.filter_map(&:role_family_id)).index_by(&:role_family_id)
    { levels:, roles:, families: }
  end

  # @return [Set<String>] the ids of the bands a later band always overrules
  def shadowed_ids
    Set.new(PayBand::Lookup.new(PayBand.order(:position).to_a, tenant_id: ActsAsTenant.current_tenant.id).shadowed.map(&:id))
  end

  # Names a band as the framework names what it matches on now, or as it
  # was when that left.
  #
  # @param band [PayBand]
  # @return [Hash]
  def band_payload(band, framework: framework_for([ band ]), names: editor_names([ band ]), shadowed: shadowed_ids)
    in_framework = take_current_names(band, framework)
    {
      pay_band_id: band.id,
      position: band.position,
      matcher: band.matcher_fields,
      level_id: band.level_id,
      role_id: band.role_id,
      role_family_id: band.role_family_id,
      level_ordinal: band.level_ordinal,
      in_framework:,
      role: band.role_name,
      level_name: band.level_name,
      level: band.level_label,
      location: band.location.presence,
      shadowed: shadowed.include?(band.id),
      currency: band.currency,
      period: band.period,
      **PayBand::FIGURES.to_h { [ it, band.figure(it) ] },
      updated_at: band.updated_at.iso8601,
      updated_by: names[editor_id(band)]
    }
  end

  # @return [Boolean] whether everything the band names is still in the framework
  def take_current_names(band, framework)
    if band.level_id
      level = framework[:levels][band.level_id] or return false
      band.take_names_from(level, framework[:roles][level.role_id])
    elsif band.role_id
      role = framework[:roles][band.role_id] or return false
      band.role_name = role.name.presence || band.role_name
    elsif band.role_family_id
      family = framework[:families][band.role_family_id] or return false
      band.role_name = family.name.presence || band.role_name
    end
    true
  end

  # @param pay_band_id [String]
  # @return [PayBand]
  # @raise [Operations::Base::ParameterError] when the tenant has no such band
  def find_band(pay_band_id)
    PayBand.find_by(id: pay_band_id.to_s) || raise(Operations::Base::ParameterError, "There is no such pay band")
  end
end
