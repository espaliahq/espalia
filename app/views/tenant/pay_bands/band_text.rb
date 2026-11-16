# frozen_string_literal: true

# How a band reads on the screen: the seats it matches, its range and midpoint
# in its own currency and period, and who changed it last.
module Views::Tenant::PayBands::BandText
  PER = { "year" => "a year", "month" => "a month", "hour" => "an hour" }.freeze

  # @param iso [String] a date, "2026-07-01"
  # @return [String] "1 Jul 2026"
  def self.day_text(iso) = Date.iso8601(iso).strftime("%-d %b %Y")

  # @param band [Hash] as Operations::Tenants::PayBands lists it
  # @return [String] the seats it matches: "Every role in Engineering, Level 3" or "Software Engineer, E2 Engineer II"
  def self.matcher_text(band)
    who = band[:role_family_id] ? "Every role in #{band[:role]}" : band[:role]
    "#{who}, #{band[:level_name]}"
  end

  # @param band [Hash]
  # @return [String] such as "Every role in Engineering, Level 3, Australia"
  def self.band_name(band) = "#{matcher_text(band)}, #{band[:location] || 'any location'}"

  private

  # @param band [Hash] as Operations::Tenants::PayBands lists it
  # @return [String] such as "AUD 120,000 to 150,000 a year"
  def range_text(band)
    "#{band[:currency]} #{amount(band[:minimum])} to #{amount(band[:maximum])} #{PER.fetch(band[:period])}"
  end

  # @param band [Hash]
  # @return [String] such as "Midpoint 135,000"
  def midpoint_text(band) = "Midpoint #{amount(band[:midpoint])}"

  # @param band [Hash]
  # @return [String] such as "Changed by Admin on 14 Nov 2026"
  def changed_text(band)
    on = Time.zone.parse(band[:updated_at]).strftime("%-d %b %Y")
    band[:updated_by] ? "Changed by #{band[:updated_by]} on #{on}" : "Changed on #{on}"
  end

  def day_text(iso) = Views::Tenant::PayBands::BandText.day_text(iso)

  def matcher_text(band) = Views::Tenant::PayBands::BandText.matcher_text(band)

  def band_name(band) = Views::Tenant::PayBands::BandText.band_name(band)

  # @param figure [String] a decimal string, "120000.00"
  # @return [String] "120,000", or "52.50" where there are cents
  def amount(figure)
    value = BigDecimal(figure)
    precision = value.frac.zero? ? 0 : 2
    ActiveSupport::NumberHelper.number_to_delimited(ActiveSupport::NumberHelper.number_to_rounded(value, precision:))
  end
end
