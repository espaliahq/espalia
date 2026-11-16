# frozen_string_literal: true

# Finds the band that prices a seat at a level and in a country (#368).
#
# A seat's attributes are its level's role, role family and level number,
# the level itself and the country's location key. Of the bands that match
# them, the last in the list has the last word ({LastMatch}). A level that
# has left the framework takes its role and number from a band made from it,
# so its seats price as they did.
#
# @example
#   lookup = PayBand::Lookup.new(PayBand.order(:position).to_a, tenant_id:)
#   band, index = lookup.deciding(level_id, "New Zealand")
class PayBand::Lookup
  # @param bands [Array<PayBand>] one tenant's bands, in order
  # @param tenant_id [String] whose framework levels the seats sit at
  def initialize(bands, tenant_id:)
    @bands = bands
    @tenant_id = tenant_id
    @levels = self.class.levels(tenant_id)
    @left = bands.select(&:level_id).reject { @levels.key?(it.level_id) }
                 .to_h { [ it.level_id, { role_id: it.role_id, role_family_id: nil, level_ordinal: it.level_ordinal } ] }
  end

  # @param level_id [String, nil]
  # @param country [String, nil] as the Org Graph holds it
  # @return [Array(PayBand, Integer), nil] the band with the last word and its index, or nil when none matches
  def deciding(level_id, country) = LastMatch.find(@bands, subject(level_id, country), PayBand::MATCHER, &:matcher)

  # @param level_id [String, nil]
  # @param country [String, nil]
  # @return [PayBand, nil]
  def covering(level_id, country) = deciding(level_id, country)&.first

  # @return [Array<PayBand>] the bands that can never have the last word, as a later band matches every seat they do
  def shadowed
    reaches = @bands.map { reach(it) }
    LastMatch.shadowed(@bands.map(&:matcher), PayBand::MATCHER, reaches:).map { @bands[it] }
  end

  # @param tenant_id [String]
  # @return [Hash{String => Hash}] each framework level's role, role family and number
  def self.levels(tenant_id)
    FrameworkState::Level.where(tenant_id:).joins(:role).pluck(:level_id, :role_id, "framework_roles.role_family_id", :ordinal)
                         .to_h { |level_id, role_id, family_id, ordinal| [ level_id, { role_id:, role_family_id: family_id, level_ordinal: ordinal } ] }
  end

  private

  def subject(level_id, country)
    level = @levels[level_id] || @left[level_id] || {}
    { **level, level_id:, location_key: PayBand.location_key(country) }
  end

  # What every seat a band matches has, built as #subject builds a seat.
  def reach(band)
    return { **(@levels[band.level_id] || @left[band.level_id]), **band.matcher.compact } if band.level_id

    band.matcher.merge(band.role_id ? { role_family_id: families[band.role_id] } : {})
  end

  def families = @families ||= FrameworkState::Role.where(tenant_id: @tenant_id, role_id: @bands.filter_map(&:role_id)).pluck(:role_id, :role_family_id).to_h
end
