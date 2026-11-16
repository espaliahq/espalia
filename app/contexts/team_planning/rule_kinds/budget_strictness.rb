# frozen_string_literal: true

# How strictly a scenario's positions must follow its budget lines
# ([#384](https://github.com/espaliahq/espalia/issues/384)). A budget line has
# no unit, so the rule is plan-wide.
#
# `match` names the dimensions a position must share with a line that states
# them, `limit` says whether money, heads or both are held to the line's
# amount and head count, and `scope` says where: each line, each cost centre
# or the whole organisation. The default, position control, matches every
# dimension and holds each line, which is how funding has always matched.
#
# @example A preset
#   { "preset" => "envelope" }
# @example Between the presets
#   { "match" => ["cost_centre", "level"], "limit" => "both", "scope" => "cost_centre" }
class TeamPlanning::RuleKinds::BudgetStrictness < TeamPlanning::RuleKind
  DIMENSIONS = %w[role level cost_centre location].freeze
  LIMITS = %w[money heads both].freeze
  SCOPES = %w[line cost_centre organisation].freeze

  PRESETS = {
    "position_control" => { "match" => DIMENSIONS, "limit" => "both", "scope" => "line" },
    "cost_centre" => { "match" => %w[cost_centre], "limit" => "both", "scope" => "cost_centre" },
    "envelope" => { "match" => [], "limit" => "money", "scope" => "organisation" }
  }.freeze

  # @return [String]
  def self.rule_name = "budget_strictness"

  # @return [String]
  def self.description
    "How strictly positions must follow budget lines. Give a preset (position_control, cost_centre or envelope) or " \
      "match, limit and scope. Set for the whole plan, never a unit"
  end

  # @return [Boolean]
  def self.plan_wide? = true

  # @return [Hash]
  def self.default = PRESETS.fetch("position_control")

  # @return [Hash]
  def self.json_schema
    { type: "object",
      properties: {
        preset: { type: "string", enum: PRESETS.keys,
                  description: "position_control: every dimension matches and each line holds. cost_centre: trades inside " \
                               "a cost centre, never across, held per cost centre. envelope: only the organisation's money total" },
        match: { type: "array", items: { type: "string", enum: DIMENSIONS },
                 description: "The dimensions a position must share with a line that states them" },
        limit: { type: "string", enum: LIMITS, description: "Whether money, heads or both are held to the budget" },
        scope: { type: "string", enum: SCOPES,
                 description: "Where the limit is checked. cost_centre needs cost_centre in match" }
      },
      additionalProperties: false }
  end

  # @param value [Hash] with string keys
  # @return [Hash] match, limit and scope, a preset written out
  # @raise [TeamPlanning::Error] for another key, an unknown value, a preset with other keys, or a cost-centre
  #   scope whose draws could cross cost centres
  def self.check(value)
    return preset(value) if value.key?("preset")

    extra = value.keys - %w[match limit scope]
    raise TeamPlanning::Error, "A budget_strictness rule takes a preset, or match, limit and scope, not #{extra.join(", ")}" if extra.any?

    match = value["match"]
    raise TeamPlanning::Error, "match must be a list of #{DIMENSIONS.join(", ")}" unless match.is_a?(Array) && (match - DIMENSIONS).empty?
    raise TeamPlanning::Error, "limit must be #{LIMITS.join(", ")}" unless LIMITS.include?(value["limit"])
    raise TeamPlanning::Error, "scope must be #{SCOPES.join(", ")}" unless SCOPES.include?(value["scope"])
    if value["scope"] == "cost_centre" && match.exclude?("cost_centre")
      raise TeamPlanning::Error, "A cost_centre scope needs cost_centre in match, or a draw could cross the cost centres its limit is checked in"
    end

    { "match" => DIMENSIONS & match, "limit" => value["limit"], "scope" => value["scope"] }
  end

  # @param value [Hash] as {.check} stored it
  # @return [String, nil] the preset it equals
  def self.preset_of(value) = PRESETS.key(value.slice("match", "limit", "scope"))

  # @param value [Hash] as {.check} stored it
  # @return [Hash] preset, match, limit and scope, as the reads report it
  def self.describe(value) = { preset: preset_of(value), match: value.fetch("match"), limit: value.fetch("limit"), scope: value.fetch("scope") }

  # @param value [Hash] as {.check} stored it
  # @return [Boolean] whether money is held to the budget
  def self.money?(value) = value.fetch("limit") != "heads"

  # @param value [Hash] as {.check} stored it
  # @return [Boolean] whether heads are held to the budget
  def self.heads?(value) = value.fetch("limit") != "money"

  def self.preset(value)
    raise TeamPlanning::Error, "A budget_strictness preset stands alone, without match, limit or scope" unless value.keys == %w[preset]

    PRESETS.fetch(value["preset"]) { raise TeamPlanning::Error, "preset must be #{PRESETS.keys.join(", ")}" }.deep_dup
  end
  private_class_method :preset
end
