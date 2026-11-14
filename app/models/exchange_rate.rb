# frozen_string_literal: true

# What one unit of a currency is worth in another, from a date (Team Planning
# 5.3). A plan spans periods, so a pair holds a rate for each date it changed.
#
# Rates convert at report time only, through {.convert}. Nothing converted is
# ever stored: a figure keeps the currency it was entered in.
class ExchangeRate < ApplicationRecord
  RATE = /\A\d{1,12}(\.\d{1,12})?\z/

  # No rate converts the pair on the date asked. A report says so rather than
  # guess, since a silent 1.0 would put the wrong total in front of a budget holder.
  class MissingRate < StandardError; end

  acts_as_tenant :tenant

  belongs_to :tenant
  belongs_to :updated_by, class_name: "User", optional: true

  normalizes :from_currency, :to_currency, with: Currency::NORMALIZE

  validates :from_currency, :to_currency, inclusion: { in: Currency::CODES, message: Currency::INVALID }
  validates :applies_from, presence: true
  validates :rate, presence: true, numericality: { greater_than: 0, less_than: 10**12 }
  validate :two_currencies
  validate :one_rate_per_pair_and_date

  # Converts an amount using the rate in force on a date: the pair's own rate,
  # or the inverse of the reverse pair's, whichever applies from later. It
  # never chains through a third currency.
  #
  # @param amount [Numeric, String]
  # @param from [String] the amount's currency
  # @param to [String] the currency wanted
  # @param on [Date] the date the amount is for
  # @return [BigDecimal] unrounded
  # @raise [MissingRate] naming the pair and the date when no rate is in force
  # @raise [ArgumentError] without a tenant, which would read every tenant's rates, or without a date
  def self.convert(amount, from:, to:, on:)
    raise ArgumentError, "ExchangeRate.convert needs a current tenant" unless ActsAsTenant.current_tenant
    raise ArgumentError, "ExchangeRate.convert needs the Date the amount is for" unless on.is_a?(Date)

    amount = BigDecimal(amount.to_s)
    from = Currency::NORMALIZE.call(from)
    to = Currency::NORMALIZE.call(to)
    return amount if from == to

    rate = in_force(from, to, on)
    raise MissingRate, "There is no exchange rate from #{from} to #{to} in force on #{on.iso8601}" unless rate

    rate.from_currency == from ? amount * rate.rate : amount / rate.rate
  end

  # @return [ExchangeRate, nil] the latest-dated rate for the pair either way round
  def self.in_force(from, to, on)
    where(from_currency: from, to_currency: to).or(where(from_currency: to, to_currency: from))
      .where(applies_from: ..on)
      .order(applies_from: :desc)
      .first
  end
  private_class_method :in_force

  # @return [String] the rate without trailing zeros, such as "0.92"
  def figure = rate.to_s("F").delete_suffix(".0")

  # @return [String] such as "NZD to AUD"
  def pair = "#{from_currency} to #{to_currency}"

  # @return [String] the refusal for a second rate on the pair's date, either way round
  def duplicate_message = "There is already a rate between #{from_currency} and #{to_currency} applying from #{applies_from&.iso8601}"

  private

  def two_currencies
    errors.add(:base, "A rate converts between two different currencies") if from_currency.present? && from_currency == to_currency
  end

  # A pair and its reverse on one date would contradict each other, so a date holds one of them.
  def one_rate_per_pair_and_date
    pair = ExchangeRate.where(from_currency:, to_currency:)
    taken = pair.or(ExchangeRate.where(from_currency: to_currency, to_currency: from_currency))
                .where(applies_from:).where.not(id:).exists?
    errors.add(:base, duplicate_message) if taken
  end
end
