# frozen_string_literal: true

# One way of working out what a seat costs on top of its base pay, such as a
# flat percentage or rates by country. The `on_cost` rule
# ({TeamPlanning::RuleKinds::OnCost}) chooses the model and its params.
#
# A model returns figures in the base's currency and never converts:
# exchange rates apply once, at report time (5.3). Figures stay exact
# Rationals, and only a display rounds them. Params may be close to pay, so a
# refusal from {.check} names what is wrong and never repeats a value.
#
# @example
#   class TeamPlanning::OnCostModels::None < TeamPlanning::OnCostModel
#     def self.model_name = "none"
#     def self.description = "No on-cost"
#     def self.on_cost_of(base, **) = Figure.new(amount: 0r, working: [])
#   end
class TeamPlanning::OnCostModel
  PERCENT = /\A\d{1,3}(\.\d{1,4})?\z/

  # @!attribute label [String] what the step adds, for a position's working
  # @!attribute amount [Rational] in the base's currency
  Step = Data.define(:label, :amount)

  # @!attribute amount [Rational] the whole on-cost, in the base's currency
  # @!attribute working [Array<Step>] how the model reached it
  Figure = Data.define(:amount, :working)

  # @return [String] the name the rule chooses the model by, in snake_case
  def self.model_name = raise(NotImplementedError, "#{name} must name its model")

  # @return [String] what the model adds, for the tools that list rules
  def self.description = raise(NotImplementedError, "#{name} must describe its model")

  # @return [Hash] a JSON Schema fragment for the params
  def self.params_schema = { type: "object" }

  # @param params [Hash] with string keys
  # @return [Hash] the params as stored
  # @raise [TeamPlanning::Error] naming what is wrong, never a value
  def self.check(params) = params

  # @param base [Rational] the seat's base pay for the stretch being priced
  # @param currency [String] the base's ISO 4217 code
  # @param country [String, nil] where the seat sits, as the Org Graph holds it
  # @param share [Rational] the part of a full-time year the base covers, which scales a fixed amount
  # @param params [Hash] as {.check} stored them
  # @return [Figure]
  # @raise [TeamPlanning::Error] when the params can't price this seat, such as a fixed amount in another currency
  def self.on_cost_of(base, currency:, country:, share:, params:) = raise(NotImplementedError, "#{name} must say how it prices a seat")

  # @param value [String, Numeric]
  # @param what [String] the param, for the refusal
  # @return [String] the percentage as stored: digits, up to four decimal places
  # @raise [TeamPlanning::Error] for anything but a percentage from 0 to 999.9999
  def self.percent!(value, what)
    text = decimal_text(value)
    raise TeamPlanning::Error, "#{what} must be a percentage, such as 12.5" unless text.match?(PERCENT)

    text
  end

  # @param value [String, Numeric]
  # @return [String] a number as typed, or a Numeric as plain decimal digits
  def self.decimal_text(value) = value.is_a?(Numeric) ? BigDecimal(value.to_s).to_s("F").delete_suffix(".0") : value.to_s.strip

  # @param percent [String] as {.percent!} stored it
  # @return [Rational] the fraction of the base
  def self.fraction(percent) = percent.to_r / 100

  # @return [String] a percentage for a step's label
  def self.shown(percent) = "#{percent}%"

  private_class_method :percent!, :decimal_text, :fraction, :shown
end
