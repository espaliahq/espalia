# frozen_string_literal: true

# Maps HiBob API employee data to Person-compatible attribute hashes.
#
# This is a pure mapping class with no side effects. It transforms
# the nested HiBob employee structure into flat attribute hashes
# suitable for Person.new / Person.update.
#
# @example
#   mapper = Hris::Hibob::ResponseMapper.new(employee_hash)
#   attrs = mapper.call
#   # => { external_id: "123", email: "alice@example.com", name: "Alice Smith", ... }
#   mapper.manager_external_id
#   # => "456"
#
class Hris::Hibob::ResponseMapper
  # Maps a single HiBob employee hash to Person attributes.
  #
  # @param employee [Hash] raw employee data from HiBob API
  # @param field_mappings [Array<HrisFieldMapping>] optional custom field mappings
  # @param level_field_id [String, nil] HiBob custom column ID for level ordinal
  # @return [Hash] attributes compatible with Person.new
  def self.call(employee, field_mappings: [], level_field_id: nil)
    new(employee, field_mappings: field_mappings, level_field_id: level_field_id).call
  end

  # @param employee [Hash] raw employee data from HiBob API
  # @param field_mappings [Array<HrisFieldMapping>] optional custom field mappings
  # @param level_field_id [String, nil] HiBob custom column ID for level ordinal
  def initialize(employee, field_mappings: [], level_field_id: nil)
    @employee = employee
    @field_mappings = field_mappings
    @level_field_id = level_field_id
  end

  # @return [Hash] mapped Person attributes
  def call
    {
      external_id: employee["id"],
      email: employee["email"]&.downcase&.strip,
      name: build_name,
      job_title: dig_human_readable_work("title") || dig_work("title"),
      department: dig_human_readable_work("department") || dig_work("department"),
      hris_source: "hibob",
      status: employee["isActive"] == false ? "inactive" : "active",
      hris_level_ordinal: extract_level_ordinal,
      hris_raw_data: employee
    }.compact
  end

  # Extracts the manager's HiBob ID from the reportsTo object.
  #
  # @return [String, nil] the HiBob ID of the manager
  def manager_external_id
    reports_to = dig_work("reportsTo")
    return nil unless reports_to.is_a?(Hash)

    reports_to["id"]
  end

  private

  attr_reader :employee, :field_mappings, :level_field_id

  # Extracts the level ordinal from the HiBob custom column.
  #
  # Reads from humanReadable.work.customColumns.<level_field_id>, which
  # (with humanReadable=APPEND) contains the display value of the list item.
  # me&u's level list uses the ordinal number as the display value.
  #
  # @return [Integer, nil]
  def extract_level_ordinal
    return nil if level_field_id.blank?

    raw = employee.dig("humanReadable", "work", "customColumns", level_field_id)
    return nil if raw.blank?

    Integer(raw.to_s, exception: false)
  end

  # @return [String, nil]
  def build_name
    display = employee["displayName"]
    return display if display.present?

    [ employee["firstName"], employee["surname"] ].compact.join(" ").presence
  end

  # @param field [String]
  # @return [Object, nil]
  def dig_work(field)
    employee.dig("work", field)
  end

  # Reads a human-readable work field from the APPEND response.
  #
  # @param field [String]
  # @return [String, nil]
  def dig_human_readable_work(field)
    employee.dig("humanReadable", "work", field)
  end
end
