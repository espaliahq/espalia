# frozen_string_literal: true

# A mapping from one or more HRIS job titles to a framework role.
#
# Two modes of operation:
#
# 1. **Title carries level** — set `level_ordinal` directly. The title itself
#    encodes both role and level (e.g. "Senior Software Engineer" → role=E, level=5).
#
# 2. **Title carries role only** — leave `level_ordinal` nil. The adapter will
#    fall back to `person.hris_level_ordinal` (populated from a separate HRIS
#    custom column configured via `HrisConfig.level_field_id`).
#
# Both modes can be mixed within a single tenant's `role_mappings` array.
#
# @example Mode 1 (title carries level)
#   HrisRoleMapping.new(
#     hris_titles: ["Senior Software Engineer"],
#     framework_role_code: "E",
#     level_ordinal: 5
#   )
#
# @example Mode 2 (level from custom column)
#   HrisRoleMapping.new(
#     hris_titles: ["Engineering Manager", "Senior Engineering Manager"],
#     framework_role_code: "EM"
#   )
#
class HrisRoleMapping
  include StoreModel::Model

  attribute :hris_titles, default: -> { [] }
  attribute :framework_role_code, :string
  attribute :level_ordinal, :integer

  validates :framework_role_code, presence: true
  validate :hris_titles_not_empty
  validates :level_ordinal, numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 20 }, allow_nil: true

  # Returns the list of titles normalized for case-insensitive matching.
  #
  # @return [Array<String>]
  def normalized_hris_titles
    Array(hris_titles).filter_map { |t| t.to_s.downcase.strip.presence }
  end

  private

  def hris_titles_not_empty
    return if Array(hris_titles).any? { |t| t.to_s.strip.present? }

    errors.add(:hris_titles, "must contain at least one non-blank title")
  end
end
