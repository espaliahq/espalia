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
  # A list field's value: the list item's id, which survives a rename, and its label.
  ListValue = Data.define(:id, :label)

  # Maps a single HiBob employee hash to Person attributes.
  #
  # @param employee [Hash] raw employee data from HiBob API
  # @param level_field_id [String, nil] the level field's path, or a bare custom-column id
  # @return [Hash] attributes compatible with Person.new
  def self.call(employee, level_field_id: nil)
    new(employee, level_field_id: level_field_id).call
  end

  # @param employee [Hash] raw employee data from HiBob API
  # @param level_field_id [String, nil] the level field's path, or a bare custom-column id
  def initialize(employee, level_field_id: nil)
    @employee = employee
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

  # The level as HiBob shows it, before any mapping to a framework: the
  # Org Graph's level fact.
  #
  # @return [String, nil] nil when no level column is configured or it is blank
  def level_label
    return nil if level_field_id.blank?

    raw = level_path.reduce(employee["humanReadable"]) { |node, key| node[key] if node.is_a?(Hash) }
    raw.to_s.strip.presence unless raw.is_a?(Hash)
  end

  # The list fields' item ids beside their labels, keyed like the attributes they sit
  # beside. A blank field is left out.
  #
  # @return [Hash{Symbol => ListValue}]
  def list_values
    {
      department: list_value(%w[work department]),
      job_title: list_value(%w[work title]),
      level: (list_value(level_path) if level_field_id.present?)
    }.compact
  end

  private

  attr_reader :employee, :level_field_id

  # HiBob returns root fields (`root.email`) at the top level, not under `root`.
  def level_path = Hris::Hibob::Client.field_path(level_field_id).delete_prefix("root.").split(".")

  # Extracts the level ordinal from the HiBob custom column.
  #
  # Reads the level field's path under humanReadable, which
  # (with humanReadable=APPEND) contains the display value of the list item.
  # me&u's level list uses the ordinal number as the display value.
  #
  # @return [Integer, nil]
  def extract_level_ordinal
    return nil if level_field_id.blank?

    raw = level_label
    return nil if raw.nil?

    Integer(raw, exception: false)
  end

  # HiBob returns a list field either nested (`work.department`) or flat
  # (`"/work/department" => { "value" => id }`); the label is only ever in the nested
  # `humanReadable` node.
  #
  # @param path [Array<String>]
  # @return [ListValue, nil]
  def list_value(path)
    flat = employee["/#{path.join('/')}"]
    id = employee.dig(*path).presence || (flat.is_a?(Hash) ? flat["value"] : flat).presence
    return nil if id.nil? || id.is_a?(Hash)

    ListValue.new(id: id.to_s, label: employee.dig("humanReadable", *path).presence)
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
