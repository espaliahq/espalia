# frozen_string_literal: true

# Named parts, summed: each a percentage of base pay, or a fixed amount a
# year for a full-time seat in a stated currency.
#
# @example params
#   { "items" => [ { "name" => "Pension", "percent" => "9" },
#                  { "name" => "Equipment", "amount" => "1200", "currency" => "EUR" } ] }
class TeamPlanning::OnCostModels::Itemised < TeamPlanning::OnCostModel
  AMOUNT = /\A\d{1,12}(\.\d{1,2})?\z/
  NAME_LENGTH = 80

  # @return [String]
  def self.model_name = "itemised"

  # @return [String]
  def self.description = "Named parts, summed: each a percentage of base pay, or a fixed amount a year for a full-time seat"

  # @return [Hash]
  def self.params_schema
    item = { type: "object",
             properties: { name: { type: "string" }, percent: { type: "string" },
                           amount: { type: "string", description: "A year, for a full-time seat" }, currency: { type: "string" } },
             required: [ "name" ] }
    { type: "object", properties: { items: { type: "array", items: item } }, required: [ "items" ] }
  end

  # @param params [Hash]
  # @return [Hash]
  # @raise [TeamPlanning::Error] for another param, a nameless or repeated part, or a part that isn't one percent or one amount
  def self.check(params)
    extra = params.keys - %w[items]
    raise TeamPlanning::Error, "An itemised on-cost takes only items, not #{extra.join(", ")}" if extra.any?

    items = params["items"]
    raise TeamPlanning::Error, "An itemised on-cost's items must be a list" unless items.is_a?(Array)

    checked = items.map { item!(it) }
    raise TeamPlanning::Error, "An itemised on-cost names one part twice" unless checked.map { it["name"].downcase }.uniq.size == checked.size

    { "items" => checked }
  end

  # @return [TeamPlanning::OnCostModel::Figure]
  # @raise [TeamPlanning::Error] for a fixed amount in another currency than the base's
  def self.on_cost_of(base, currency:, country:, share:, params:)
    working = params["items"].map do |item|
      next Step.new(label: "#{item["name"]}: #{shown(item["percent"])} of base pay", amount: base * fraction(item["percent"])) if item["percent"]

      unless item["currency"] == currency
        raise TeamPlanning::Error, "#{item["name"]} is a fixed amount in #{item["currency"]}, and this seat is priced in #{currency}"
      end

      Step.new(label: "#{item["name"]}: a fixed amount, for #{year_shown(share)}", amount: item["amount"].to_r * share)
    end
    Figure.new(amount: working.sum(0r, &:amount), working:)
  end

  def self.item!(item)
    raise TeamPlanning::Error, "Each part of an itemised on-cost must be an object" unless item.is_a?(Hash)

    extra = item.keys - %w[name percent amount currency]
    raise TeamPlanning::Error, "A part takes only name, percent, amount and currency, not #{extra.join(", ")}" if extra.any?

    name = item["name"].to_s.squish
    raise TeamPlanning::Error, "Each part of an itemised on-cost needs a name" if name.empty?
    raise TeamPlanning::Error, "A part's name is at most #{NAME_LENGTH} characters" if name.length > NAME_LENGTH
    raise TeamPlanning::Error, "#{name} must have a percent or an amount and currency, not both" if item.key?("percent") == item.key?("amount")

    if item.key?("percent")
      raise TeamPlanning::Error, "#{name} is a percentage, so it takes no currency" if item.key?("currency")

      return { "name" => name, "percent" => percent!(item["percent"], "#{name}'s percent") }
    end

    amount = decimal_text(item["amount"])
    raise TeamPlanning::Error, "#{name}'s amount must be a number, such as 1200 or 1200.50" unless amount.match?(AMOUNT)

    code = Currency::NORMALIZE.(item["currency"])
    raise TeamPlanning::Error, "#{name}'s currency #{Currency::INVALID}" unless Currency::CODES.include?(code)

    { "name" => name, "amount" => amount, "currency" => code }
  end

  def self.year_shown(share)
    return "a full-time year" if share == 1

    "#{BigDecimal(share * 100, 12).round(2).to_s("F").delete_suffix(".0")}% of a full-time year"
  end

  private_class_method :item!, :year_shown
end
