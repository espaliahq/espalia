# frozen_string_literal: true

# Which cost centre a seat draws on where nothing more authoritative decides
# ([#387](https://github.com/espaliahq/espalia/issues/387)): an ordered list
# of entries, each a matcher and a label, read as pay bands are read. Every
# entry that matches applies, so the last one to match has the last word
# ({LastMatch}).
#
# A matcher names any of a unit (and so its subtree), a role or a role
# family (never both), a level number and a location, and ignores the
# fields it leaves out. A location matches ignoring case and spacing.
#
# The kind first stored a `rules` list where the first match won. RuleSet
# events can't be rewritten, so a stored `rules` list reads as its entries
# in reverse, which picks the same rule for every seat.
#
# @example
#   { "entries" => [ { "role_family_id" => engineering_id, "cost_centre" => "Engineering" },
#                    { "unit_id" => venues_id, "cost_centre" => "Venues" } ] }
class TeamPlanning::RuleKinds::CostCentre < TeamPlanning::RuleKind
  IDS = %w[unit_id role_id role_family_id].freeze
  MATCHERS = (IDS + %w[level_ordinal location]).freeze
  KEYS = (MATCHERS + %w[cost_centre]).freeze
  FIELDS = MATCHERS.map(&:to_sym).freeze
  MAX_ENTRIES = 200

  # @return [String]
  def self.rule_name = "cost_centre"

  # @return [String]
  def self.description
    "Which cost centre a seat draws on, as an ordered list of a matcher and a label; every entry that matches applies, so the last has the last word"
  end

  # @return [Hash]
  def self.default = { "entries" => [] }

  # @return [Hash]
  def self.json_schema
    entry = { type: "object", required: [ "cost_centre" ], additionalProperties: false,
              description: "Names at least one matcher, and never both role_id and role_family_id",
              properties: { unit_id: { type: "string", description: "A unit, matching it and every unit below it" },
                            role_id: { type: "string" }, role_family_id: { type: "string", description: "Not with role_id" },
                            level_ordinal: { type: "integer", minimum: 1, description: "A level number" },
                            location: { type: "string", description: "A country, matched ignoring case and spacing" },
                            cost_centre: { type: "string", maxLength: TeamPlanning::Events::PositionSet::COST_CENTRE_LENGTH } },
              anyOf: MATCHERS.map { { required: [ it ] } }, not: { required: %w[role_id role_family_id] } }
    { type: "object", additionalProperties: false, required: [ "entries" ],
      properties: { entries: { type: "array", items: entry, maxItems: MAX_ENTRIES,
                               description: "In order; the last entry that matches a seat decides its cost centre" } } }
  end

  # @param value [Hash] with string keys: `entries`, or a first-match `rules` list from before
  # @return [Hash] `entries`, each id downcased and each label and location squished
  # @raise [TeamPlanning::Error] for another key, an entry without a matcher or label, or one naming a role and a family
  def self.check(value)
    extra = value.keys - %w[entries rules]
    raise TeamPlanning::Error, "A cost_centre rule takes only entries, not #{extra.join(", ")}" if extra.any?
    raise TeamPlanning::Error, "A cost_centre rule takes entries or rules, not both" if value.key?("entries") && value.key?("rules")

    listed = value.fetch("entries") { value.fetch("rules", []) }
    raise TeamPlanning::Error, "A cost_centre rule's entries must be a list" unless listed.is_a?(Array)
    raise TeamPlanning::Error, "A cost_centre rule holds at most #{MAX_ENTRIES} entries" if listed.size > MAX_ENTRIES

    entries = listed.map { entry!(it) }
    { "entries" => value.key?("rules") ? entries.reverse : entries }
  end

  # @param value [Hash] as stored, by {.check} now or as a `rules` list before
  # @return [Array<Hash>] the entries in order
  def self.entries(value) = value["entries"] || value.fetch("rules", []).reverse

  # @param entry [Hash] one of {.entries}
  # @return [Hash{Symbol => Object}] what it matches on, its location as a key
  def self.matcher(entry)
    FIELDS.to_h { [ it, entry[it.to_s] ] }.merge(location: location_key(entry["location"]))
  end

  # @param location [String, nil]
  # @return [String, nil] the location as entries and seats compare it
  def self.location_key(location) = location.to_s.squish.downcase.presence

  # @param value [Hash] as stored
  # @param unit_ids [Array<String>] the seat's unit and every unit above it
  # @param role_id [String, nil]
  # @param role_family_id [String, nil]
  # @param level_ordinal [Integer, nil]
  # @param location [String, nil]
  # @return [Array(Hash, Integer), nil] the entry with the last word and its place in the list, nil when none matches
  def self.match(value, unit_ids:, role_id:, role_family_id:, level_ordinal: nil, location: nil)
    subject = { unit_id: unit_ids, role_id:, role_family_id:, level_ordinal:, location: location_key(location) }
    LastMatch.find(entries(value), subject, FIELDS) { matcher(it) }
  end

  # @param value [Hash] as stored
  # @param families [Hash{String => String}] each role's family
  # @param chains [#call] a unit id to it and every unit above it
  # @return [Array<Integer>] the places of the entries that never have the last word, as a later one matches every seat they do
  def self.shadowed(value, families:, chains:)
    matchers = entries(value).map { matcher(it) }
    reaches = matchers.map do |matcher|
      matcher.merge(unit_id: matcher[:unit_id] && chains.call(matcher[:unit_id]),
                    role_family_id: matcher[:role_family_id] || families[matcher[:role_id]])
    end
    LastMatch.shadowed(matchers, FIELDS, reaches:)
  end

  def self.entry!(entry)
    raise TeamPlanning::Error, "Each cost centre entry must be an object" unless entry.is_a?(Hash)

    extra = entry.keys - KEYS
    raise TeamPlanning::Error, "A cost centre entry takes only #{KEYS.join(", ")}, not #{extra.join(", ")}" if extra.any?

    matcher = { **IDS.to_h { [ it, entry[it].to_s.strip.downcase.presence ] }, "level_ordinal" => ordinal!(entry["level_ordinal"]),
                "location" => entry["location"].to_s.squish.presence }.compact
    raise TeamPlanning::Error, "Each cost centre entry names a unit, role, role family, level or location" if matcher.empty?
    raise TeamPlanning::Error, "A cost centre entry names a role or a role family, not both" if matcher.key?("role_id") && matcher.key?("role_family_id")

    { **matcher, "cost_centre" => label!(entry["cost_centre"]) }
  end

  def self.ordinal!(ordinal)
    return if ordinal.nil? || ordinal.to_s.strip.empty?

    number = Integer(ordinal.to_s.strip, exception: false)
    raise TeamPlanning::Error, "A cost centre entry's level is a whole number from 1" unless number && number >= 1

    number
  end

  def self.label!(label)
    label = label.to_s.squish
    raise TeamPlanning::Error, "Each cost centre entry names a cost centre" if label.empty?

    length = TeamPlanning::Events::PositionSet::COST_CENTRE_LENGTH
    raise TeamPlanning::Error, "A cost centre is at most #{length} characters" if label.length > length

    label
  end

  private_class_method :entry!, :ordinal!, :label!
end
