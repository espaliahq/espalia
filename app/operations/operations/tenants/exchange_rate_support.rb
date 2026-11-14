# frozen_string_literal: true

# What the exchange rate tools share with the pay band ones: the admin-only
# check and who changed a row. A refusal never repeats a rate.
module Operations::Tenants::ExchangeRateSupport
  include Operations::Tenants::PayBandSupport
  include Operations::OrgGraph::DateParameter

  RATE_SCHEMA = { type: "string", pattern: ExchangeRate::RATE.source.sub("\\A", "^").sub("\\z", "$") }.freeze
  RATE_HELP = "A rate is a decimal string above zero with at most twelve decimal places, such as \"0.92\": " \
              "one unit of from_currency is worth that much to_currency."

  private

  # @return [BigDecimal]
  def rate_value
    value = params[:rate].to_s.strip
    unless value.match?(ExchangeRate::RATE) && BigDecimal(value).positive?
      raise Operations::Base::ParameterError, "rate must be a number above zero with at most twelve decimal places"
    end

    BigDecimal(value)
  end

  # @param record [ExchangeRate, ReferenceCurrency]
  # @raise [Operations::Base::ParameterError] naming what is wrong, never a rate
  def save_setting!(record)
    record.updated_by = context.user
    return record if record.save

    raise Operations::Base::ParameterError, record.errors.full_messages.to_sentence
  rescue ActiveRecord::RecordNotUnique
    raise Operations::Base::ParameterError, record.try(:duplicate_message) || "Someone else set it at the same moment; try again"
  end

  # @param rate [ExchangeRate]
  # @return [Hash]
  def rate_payload(rate, names: editor_names([ rate ]))
    {
      exchange_rate_id: rate.id,
      from_currency: rate.from_currency,
      to_currency: rate.to_currency,
      rate: rate.figure,
      applies_from: rate.applies_from.iso8601,
      updated_at: rate.updated_at.iso8601,
      updated_by: names[rate.updated_by_id]
    }
  end

  # @param reference [ReferenceCurrency, nil]
  # @return [Hash, nil]
  def reference_payload(reference, names: editor_names([ reference ].compact))
    reference && { currency: reference.currency, updated_at: reference.updated_at.iso8601, updated_by: names[reference.updated_by_id] }
  end

  # @param exchange_rate_id [String]
  # @return [ExchangeRate]
  # @raise [Operations::Base::ParameterError] when the tenant has no such rate
  def find_rate(exchange_rate_id)
    ExchangeRate.find_by(id: exchange_rate_id.to_s) || raise(Operations::Base::ParameterError, "There is no such exchange rate")
  end
end
