# frozen_string_literal: true

# Capacity in units, where one unit is roughly what a solid mid-level
# contributor delivers, net of routine overhead
# ([#265](https://github.com/espaliahq/espalia/issues/265)).
#
# A seat's base comes from a curve by level, linear up to a knee and then
# saturating, so a very senior person isn't worth several juniors. Managing
# costs units outright: a fixed cost by the manager's level, plus a cost per
# report by distance, weighted by the report's level. Reports come from the
# reporting graph ({Graph}), never from who sits in a unit. Contribution is
# the base less that cost, floored at zero, then scaled by the place's share
# and the seat's FTE.
#
# Every number is a parameter a tenant sets in the `capacity_model` rule.
# The defaults are illustrative, not any organisation's figures.
class TeamPlanning::CapacityModels::Units < TeamPlanning::CapacityModel
  DEFAULTS = {
    "base" => { "start" => "0.4", "slope" => "0.3", "knee" => 4, "decay" => "0.5" },
    "fixed_cost" => { "default" => "0.1", "by_level" => {} },
    "per_report" => { "direct" => "0.1", "skip" => "0.03", "deeper" => "0.01" },
    "report_weight" => { "default" => "1", "by_level" => { "1" => "1.5", "2" => "1.25" } },
    "manager_role_ids" => []
  }.freeze

  # The parameters, as exact numbers.
  Settings = Data.define(:start, :slope, :knee, :decay, :fixed_cost, :fixed_by_level, :per_report, :weight, :weight_by_level,
                         :manager_role_ids) do
    # A framework whose levels start below 1 reads them on the same line,
    # never below zero.
    #
    # @param ordinal [Integer]
    # @return [Rational]
    def base(ordinal)
      linear = [ start + slope * ([ ordinal, knee ].min - 1), 0r ].max
      return linear if ordinal <= knee

      linear + slope * (1..(ordinal - knee)).sum(0r) { decay**it }
    end

    # @return [Rational]
    def fixed(ordinal) = fixed_by_level.fetch(ordinal, fixed_cost)

    # @param ordinal [Integer, nil]
    # @return [Rational]
    def weight_at(ordinal) = ordinal ? weight_by_level.fetch(ordinal, weight) : weight
  end

  # @return [String]
  def self.model_name = "units"

  # @return [String]
  def self.description = "Units on a curve by level, less what managing the seat's reports costs"

  # @return [String]
  def self.symbol = "u"

  # @return [Hash{String => String}]
  def self.notes = Graph::NOTES

  # @param params [Hash] with string keys
  # @return [Hash]
  # @raise [TeamPlanning::Error] naming the key at fault, never its value
  def self.check(params)
    unknown = params.keys - DEFAULTS.keys
    raise TeamPlanning::Error, "units takes no #{unknown.join(", ")}" if unknown.any?

    DEFAULTS.except("manager_role_ids").each_key do |group|
      next unless params.key?(group)
      raise TeamPlanning::Error, "units #{group} must be an object" unless params[group].is_a?(Hash)

      extra = params[group].keys - DEFAULTS[group].keys
      raise TeamPlanning::Error, "units #{group} takes no #{extra.join(", ")}" if extra.any?
    end
    settings(params)
    params
  end

  # @param seat [TeamPlanning::CapacityModel::Seat]
  # @param place [TeamPlanning::CapacityModel::Place]
  # @param params [Hash]
  # @param map [TeamPlanning::Baseline::Map]
  # @param facts [TeamPlanning::CapacityModel::Facts]
  # @return [TeamPlanning::CapacityModel::Figure]
  def self.capacity_of(seat, place:, params:, map:, facts: Facts.new)
    settings = facts.cache[[ :units_settings, params ]] ||= settings(params)
    ordinal = facts.ordinal_of[place.level_id]
    return Figure.new(amount: 0r, working: [], reason: "no_level") unless ordinal

    graph = facts.cache[[ :units_graph, settings.manager_role_ids ]] ||= Graph.new(map:, facts:, manager_role_ids: settings.manager_role_ids)
    base = settings.base(ordinal)
    steps = [ Step.new(label: "Base at L#{ordinal}", amount: base, op: "+") ]
    steps += costs(seat, ordinal, settings, graph, facts) if graph.manager?(seat.id)
    net = steps.sum(0r, &:amount)
    steps << Step.new(label: "Floored at zero: managing costs more than the base", amount: -net, op: "+") if net.negative?
    amount = [ net, 0r ].max
    steps += scaling(seat, place)
    amount *= place.allocation * seat.fte
    Figure.new(amount:, working: steps + [ Step.new(label: "Units", amount:, op: "=") ], overloaded: net.negative?,
               excess: [ -net, 0r ].max, notes: graph.notes_for(seat.id))
  end

  class << self
    private

    def costs(seat, ordinal, settings, graph, facts)
      fixed = settings.fixed(ordinal)
      reports = graph.span(seat.id).map do |report|
        level = facts.level_of[report.id]
        cost = settings.per_report.fetch(report.distance) * settings.weight_at(level) * report.fte
        TeamPlanning::CapacityModel::Step.new(label: report_label(report, level), amount: -cost, op: "+", subject_id: report.id)
      end
      [ TeamPlanning::CapacityModel::Step.new(label: "Fixed cost of managing at L#{ordinal}", amount: -fixed, op: "+"), *reports ]
    end

    def report_label(report, level)
      who = report.kind == "position" ? "Open seat, #{report.distance}" : "Report, #{report.distance}"
      at = level ? "L#{level}" : "level unknown, default weight"
      fte = report.kind == "position" ? ", × open FTE #{report.fte.to_f.round(4)}" : ""
      "#{who}, #{at}#{fte}"
    end

    def scaling(seat, place)
      steps = []
      unless place.allocation == 1 && place.allocation_known
        label = place.allocation_known ? "× share of the seat in this place" : "× share not recorded, split from what the other places leave"
        steps << TeamPlanning::CapacityModel::Step.new(label:, amount: place.allocation, op: "×")
      end
      unless seat.fte == 1 && seat.fte_known
        label = seat.kind == "position" ? "× open FTE" : (seat.fte_known ? "× FTE" : "× FTE not recorded, counted as 1")
        steps << TeamPlanning::CapacityModel::Step.new(label:, amount: seat.fte, op: "×")
      end
      steps
    end

    def settings(params)
      group = ->(name) { DEFAULTS[name].merge(params.fetch(name, {})) }
      base = group.("base")
      fixed = group.("fixed_cost")
      per_report = group.("per_report")
      weight = group.("report_weight")
      Settings.new(
        start: number!("base start", base["start"]), slope: number!("base slope", base["slope"]),
        knee: level!("base knee", base["knee"]), decay: decay!(base["decay"]),
        fixed_cost: number!("fixed_cost default", fixed["default"]), fixed_by_level: by_level!("fixed_cost", fixed["by_level"]),
        per_report: %w[direct skip deeper].to_h { [ it, number!("per_report #{it}", per_report[it]) ] },
        weight: number!("report_weight default", weight["default"]), weight_by_level: by_level!("report_weight", weight["by_level"]),
        manager_role_ids: role_ids!(params.fetch("manager_role_ids", []))
      )
    end

    def number!(key, value)
      number = Rational(value.to_s)
      raise ArgumentError if number.negative?

      number
    rescue ArgumentError, ZeroDivisionError, TypeError
      raise TeamPlanning::Error, "units #{key} must be a number of at least zero"
    end

    def decay!(value)
      decay = number!("base decay", value)
      raise TeamPlanning::Error, "units base decay must be below 1" unless decay < 1

      decay
    end

    def level!(key, value)
      ordinal = Integer(value.to_s, exception: false)
      raise TeamPlanning::Error, "units #{key} must be a whole level of at least 1" unless ordinal&.positive?

      ordinal
    end

    def by_level!(group, levels)
      raise TeamPlanning::Error, "units #{group} by_level must be an object" unless levels.is_a?(Hash)

      levels.to_h { |level, value| [ ordinal!("#{group} by_level", level), number!("#{group} by_level", value) ] }
    end

    def ordinal!(key, value)
      Integer(value.to_s, exception: false) or raise TeamPlanning::Error, "units #{key} must be a whole level"
    end

    def role_ids!(ids)
      raise TeamPlanning::Error, "units manager_role_ids must be a list of role ids" unless ids.is_a?(Array) && ids.all?(String)

      ids.map { it.strip.downcase }.uniq.sort
    end
  end
end
