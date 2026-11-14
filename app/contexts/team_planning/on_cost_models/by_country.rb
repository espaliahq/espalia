# frozen_string_literal: true

# A percentage of base pay for each country, and one for every other. A
# country is matched as the Org Graph holds it, ignoring case and spacing,
# since the HRIS gives it as free text.
#
# @example params
#   { "percents" => { "Atlantis" => "14" }, "otherwise" => "10" }
class TeamPlanning::OnCostModels::ByCountry < TeamPlanning::OnCostModel
  # @return [String]
  def self.model_name = "by_country"

  # @return [String]
  def self.description = "A percentage of base pay for each country, and one for every other"

  # @return [Hash]
  def self.params_schema
    { type: "object",
      properties: { percents: { type: "object", description: "Country => percentage", additionalProperties: { type: "string" } },
                    otherwise: { type: "string", description: "For a country not listed, or none recorded" } },
      required: [ "otherwise" ] }
  end

  # @param params [Hash]
  # @return [Hash] each country squished
  # @raise [TeamPlanning::Error] for another param, a blank or repeated country, or a percent that isn't one
  def self.check(params)
    extra = params.keys - %w[percents otherwise]
    raise TeamPlanning::Error, "An on-cost by country takes only percents and otherwise, not #{extra.join(", ")}" if extra.any?

    percents = params.fetch("percents", {})
    raise TeamPlanning::Error, "An on-cost by country's percents must be an object" unless percents.is_a?(Hash)

    countries = percents.keys.map { it.to_s.squish }
    raise TeamPlanning::Error, "An on-cost by country names a blank country" if countries.any?(&:blank?)
    raise TeamPlanning::Error, "An on-cost by country names one country twice" unless countries.map(&:downcase).uniq.size == countries.size

    { "percents" => countries.zip(percents.values).to_h { |country, percent| [ country, percent!(percent, "Each country's percent") ] },
      "otherwise" => percent!(params["otherwise"], "An on-cost by country's otherwise") }
  end

  # @return [TeamPlanning::OnCostModel::Figure]
  def self.on_cost_of(base, currency:, country:, share:, params:)
    key = country.to_s.squish.downcase
    listed = params["percents"].find { |name, _| name.downcase == key }
    percent = listed ? listed.last : params["otherwise"]
    where = if listed then "in #{listed.first}"
    elsif key.empty? then "with no country recorded"
    else "in a country not listed"
    end

    amount = base * fraction(percent)
    Figure.new(amount:, working: [ Step.new(label: "#{shown(percent)} of base pay, #{where}", amount:) ])
  end
end
