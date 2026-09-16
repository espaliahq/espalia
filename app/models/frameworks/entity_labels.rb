# frozen_string_literal: true

# The ONE mapping from a framework entity type identifier to the word users
# read. `role_illustration` is the reason this exists: the domain calls it an
# illustration everywhere (events, read models, tables, params, MCP tool names)
# while every user-facing surface says **example** — see
# docs/guidelines/framework-explorer.md, "Terminology".
#
# Use it wherever an entity type reaches a person: suggestion badges, activity
# feed entries, and the flash / inline error messages raised by the aggregate
# and the Operations. Do NOT use it when the message names the value a caller
# supplied to a typed API parameter and that value is unknown or invalid
# ("Unknown entity type: x") — echoing the identifier back is the useful thing
# there, and an unmapped type has no label anyway.
#
# @example
#   Frameworks::EntityLabels.for("role_illustration")       # => "Example"
#   Frameworks::EntityLabels.humanized("role_illustration") # => "example"
#
class Frameworks::EntityLabels
  LABELS = {
    "role_illustration" => "Example",
    "behavioural_expectation" => "Expectation",
    "capability" => "Capability",
    "capability_category" => "Category",
    "role" => "Role",
    "role_family" => "Role family",
    "level" => "Level"
  }.freeze

  # Title-case label for an entity type, for a badge or the start of a sentence.
  #
  # @param entity_type [String, Symbol, nil]
  # @return [String] the label, or the humanized identifier when unmapped
  def self.for(entity_type)
    LABELS.fetch(entity_type.to_s) { entity_type.to_s.humanize.presence || "change" }
  end

  # Lower-case label, for use mid-sentence ("You have already proposed
  # deleting this example").
  #
  # @param entity_type [String, Symbol, nil]
  # @return [String]
  def self.humanized(entity_type)
    self.for(entity_type).downcase
  end
end
