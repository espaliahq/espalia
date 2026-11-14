# frozen_string_literal: true

# What a tenant pays at one framework level in one location: a minimum,
# midpoint and maximum, in the band's own currency and per its own period.
# Team Planning prices positions from these (Team Planning 5.1).
#
# Figures are kept exactly as entered. Nothing is converted or annualised:
# conversion to a reference currency happens once, at report time.
#
# A blank location is the band for any location, used where no band names
# the person's country.
class PayBand < ApplicationRecord
  PERIODS = %w[year month hour].freeze
  FIGURES = %i[minimum midpoint maximum].freeze

  acts_as_tenant :tenant

  belongs_to :tenant
  belongs_to :updated_by, class_name: "User", optional: true

  normalizes :location, with: ->(location) { known_spelling(location.to_s.squish) }, apply_to_nil: true
  normalizes :currency, with: Currency::NORMALIZE

  before_validation { self.location_key = self.class.location_key(location) }

  validates :level_id, presence: true
  validates :role_name, :level_name, presence: true
  validates :currency, inclusion: { in: Currency::CODES, message: Currency::INVALID }
  validates :period, inclusion: { in: PERIODS, message: "must be year, month or hour" }
  validates(*FIGURES, presence: true, numericality: { greater_than_or_equal_to: 0, less_than: 10**12 })
  validate :figures_in_order
  validate :one_band_per_level_and_location

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

  # Where a band sits on the screen: by role, then from the lowest level,
  # then the any-location band before the countries. A band whose level has
  # left the framework sits last.
  #
  # @param band [PayBand]
  # @param level [FrameworkState::Level, nil] the band's level, if still in the framework
  # @return [Array]
  def self.page_order(band, level)
    [ level ? 0 : 1, band.role_name, level&.role_id.to_s, level&.ordinal || 0, band.level_name, band.location_key ]
  end

  # Takes the level and copies its names, so the band still reads once the
  # level leaves the framework.
  #
  # @param level [FrameworkState::Level]
  # @param role [FrameworkState::Role, nil] the level's role, when the caller holds it
  def take_names_from(level, role = FrameworkState::Role.find_by(role_id: level.role_id))
    self.level_id = level.level_id
    self.role_name = role&.name.presence || "Unnamed role"
    self.level_name = "#{level.code} #{level.title}".strip
  end

  alias level= take_names_from

  # @return [String] such as "Software Engineer, E4 Staff Engineer"
  def level_label = "#{role_name}, #{level_name}"

  # A figure with both its decimal places, as entered: "120000.00".
  #
  # @param name [Symbol] :minimum, :midpoint or :maximum
  # @return [String]
  def figure(name)
    whole, fraction = public_send(name).to_s("F").split(".")
    "#{whole}.#{fraction.to_s.ljust(2, '0')}"
  end

  # @return [String] the location as the screen reads it
  def location_name = any_location? ? "Any location" : location

  # @return [Boolean] whether this is the fallback band for any location
  def any_location? = location_key.blank?

  # @return [String] the refusal for a second band at this level and location
  def duplicate_message = "There is already a band for this level in #{any_location? ? 'any location' : location}"

  private

  def figures_in_order
    return unless FIGURES.all? { public_send(it).is_a?(Numeric) }
    return if minimum <= midpoint && midpoint <= maximum

    errors.add(:base, "The minimum can't be above the midpoint, nor the midpoint above the maximum")
  end

  def one_band_per_level_and_location
    taken = PayBand.where(level_id:, location_key:).where.not(id:).exists?
    errors.add(:base, duplicate_message) if taken
  end
end
