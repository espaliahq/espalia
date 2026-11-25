# frozen_string_literal: true

# What a tenant pays at one framework level in one location: a minimum,
# midpoint and maximum, in the band's own currency and per its own period.
# Team Planning prices positions from these (Team Planning 5.1).
#
# Figures are kept exactly as entered. Nothing is converted or annualised:
# conversion to a reference currency happens once, at report time.
#
# Bands form an ordered list ([#368](https://github.com/espaliahq/espalia/issues/368)). Each band matches on whichever of role
# family, role, level number and location it sets, and of the bands that
# match a seat, the last in the list has the last word ({LastMatch}). A
# blank location matches any location. A band made from a framework level
# also keeps its level_id, legacy matching that lets a seat at a level that
# has left the framework still find its band; an admin never sets it.
class PayBand < ApplicationRecord
  MATCHER = %i[role_family_id role_id level_ordinal level_id location_key].freeze
  EVERY_ROLE = "Every role"
  EVERY_LEVEL = "Every level"
  PERIODS = %w[year month hour].freeze
  PER_YEAR = { "year" => 1, "month" => 12 }.freeze
  FIGURES = %i[minimum midpoint maximum].freeze

  acts_as_tenant :tenant

  belongs_to :tenant
  belongs_to :updated_by, class_name: "User", optional: true

  normalizes :location, with: ->(location) { known_spelling(location.to_s.squish) }, apply_to_nil: true
  normalizes :currency, with: Currency::NORMALIZE

  before_validation { self.location_key = self.class.location_key(location) }

  validates :level_ordinal, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validate :role_or_family
  validates :role_name, :level_name, presence: true
  validates :currency, inclusion: { in: Currency::CODES, message: Currency::INVALID }
  validates :period, inclusion: { in: PERIODS, message: "must be year, month or hour" }
  validates(*FIGURES, presence: true, numericality: { greater_than_or_equal_to: 0, less_than: 10**12 })
  validate :figures_in_order

  # The one matching rule for a band's location against the Org Graph's
  # country: case-insensitive, with spaces squeezed and the ends trimmed.
  #
  # @param location [String, nil]
  # @return [String] "" for any location
  def self.location_key(location) = location.to_s.squish.downcase

  # @param location [String]
  # @return [String] the Org Graph's spelling of the country, where it holds one
  def self.known_spelling(location)
    return location if location.empty?

    current_sites.where("regexp_replace(lower(btrim(value->>'country')), '\\s+', ' ', 'g') = ?", location_key(location))
                 .pick(Arel.sql("value->>'country'"))&.squish || location
  end

  # The countries the Org Graph holds for people now, for the location field.
  #
  # @return [Array<String>] sorted, one spelling per country
  def self.known_countries
    current_sites.distinct.pluck(Arel.sql("value->>'country'"))
                 .filter_map { it.to_s.squish.presence }
                 .uniq { location_key(it) }.sort
  end

  # @return [ActiveRecord::Relation<OrgFactPeriod>] each person's site in effect today, not one scheduled
  def self.current_sites = OrgFactPeriod.current.in_effect_on(Date.current).where(subject_type: "person", fact: "site")

  # Runs the block in a transaction that holds the tenant's band list. The
  # previous release takes it before writing any band, and every planning
  # input command takes it before the stream's lock, so the two releases
  # never write the list at once while a deploy is under way.
  #
  # @param tenant_id [String]
  # @return [Object] the block's value
  def self.with_list_lock(tenant_id)
    transaction do
      connection.execute(sanitize_sql_array([ "SELECT pg_advisory_xact_lock(hashtextextended(?, 0))", "pay_bands:#{tenant_id}" ]))
      yield if block_given?
    end
  end

  # Takes the level and copies its names, so the band still reads once the
  # level leaves the framework.
  #
  # @param level [FrameworkState::Level]
  # @param role [FrameworkState::Role, nil] the level's role, when the caller holds it
  def take_names_from(level, role = FrameworkState::Role.find_by(role_id: level.role_id))
    self.level_id = level.level_id
    self.role_id = level.role_id
    self.level_ordinal = level.ordinal
    self.role_family_id = nil
    self.role_name = role&.name.presence || "Unnamed role"
    self.level_name = "#{level.code} #{level.title}".strip
  end

  alias level= take_names_from

  # Sets what the band matches on and copies the names, so the band still
  # reads once they leave the framework. A role and a level number that name
  # a framework level match as that level.
  #
  # @param role [FrameworkState::Role, nil]
  # @param role_family [FrameworkState::RoleFamily, nil]
  # @param level_ordinal [Integer, nil]
  def match_on(role: nil, role_family: nil, level_ordinal: nil)
    level = role && level_ordinal && FrameworkState::Level.find_by(role_id: role.role_id, ordinal: level_ordinal)
    return take_names_from(level, role) if level

    assign_attributes(level_id: nil, role_id: role&.role_id, role_family_id: role_family&.role_family_id, level_ordinal:)
    self.role_name = if role then role.name.presence || "Unnamed role"
    elsif role_family then role_family.name.presence || "Unnamed role family"
    else EVERY_ROLE
    end
    self.level_name = level_ordinal ? "Level #{level_ordinal}" : EVERY_LEVEL
  end

  # @return [String] such as "Software Engineer, E4 Staff Engineer" or "Engineering, Level 4"
  def level_label = "#{role_name}, #{level_name}"

  # A band made from a framework level matches on the level alone, which
  # holds its role and number: the framework can renumber a level, and one
  # that has left the framework has neither.
  #
  # @return [Hash{Symbol => Object}] the fields the band matches on, nil where it matches anything
  def matcher
    return { role_family_id: nil, role_id: nil, level_ordinal: nil, level_id:, location_key: location_key.presence } if level_id

    { role_family_id:, role_id:, level_ordinal:, level_id: nil, location_key: location_key.presence }
  end

  # The fields an admin sets, for the tools and the working. A band made
  # from a framework level reports the level, not the role and number it
  # was made with, which can go stale.
  #
  # @return [Hash{Symbol => Object}] only the fields set
  def matcher_fields
    return { level_id:, location: location.presence }.compact if level_id

    { role_family_id:, role_id:, level_ordinal:, location: location.presence }.compact
  end

  # How narrow the band is, for where a new band lands: a role counts above
  # its family, a level number and a country one each.
  #
  # @return [Integer]
  def specificity = self.class.specificity(role_family_id:, role_id:, level_ordinal:, level_id:, location_key:)

  # @param (see #matcher)
  # @return [Integer] as {#specificity}, from a band's matcher fields
  def self.specificity(role_family_id:, role_id:, level_ordinal:, level_id:, location_key:)
    reach = role_id || level_id ? 2 : (role_family_id ? 1 : 0)
    reach + (level_ordinal || level_id ? 1 : 0) + (location_key.blank? ? 0 : 1)
  end

  # A figure with both its decimal places, as entered: "120000.00".
  #
  # @param name [Symbol] :minimum, :midpoint or :maximum
  # @return [String]
  def figure(name)
    whole, fraction = public_send(name).to_s("F").split(".")
    "#{whole}.#{fraction.to_s.ljust(2, '0')}"
  end

  # A figure for a full-time year, exactly.
  #
  # @param name [Symbol] :minimum, :midpoint or :maximum
  # @param hours_per_year [Rational] for an hourly band
  # @return [Rational]
  def yearly(name, hours_per_year:) = self.class.yearly(public_send(name).to_r, period:, hours_per_year:)

  # @param figure [Rational] an amount per period
  # @param period [String] "year", "month" or "hour"
  # @param hours_per_year [Rational, nil] for an hourly figure
  # @return [Rational]
  def self.yearly(figure, period:, hours_per_year:) = period == "hour" ? figure * hours_per_year : figure * PER_YEAR.fetch(period)

  # @return [String] the location as the screen reads it
  def location_name = any_location? ? "Any location" : location

  # @return [Boolean] whether this is the fallback band for any location
  def any_location? = location_key.blank?

  # @return [String] the refusal for a second band that matches the same seats, from its names
  def self.duplicate_message(role_name:, level_name:, location:)
    "There is already a band for #{role_name}, #{level_name} in #{location.presence || 'any location'}"
  end

  private

  def figures_in_order
    return unless FIGURES.all? { public_send(it).is_a?(Numeric) }
    return if minimum <= midpoint && midpoint <= maximum

    errors.add(:base, "The minimum can't be above the midpoint, nor the midpoint above the maximum")
  end

  def role_or_family
    errors.add(:base, "A band matches on a role or a role family, not both: a role already names its family") if role_id && role_family_id
  end
end
