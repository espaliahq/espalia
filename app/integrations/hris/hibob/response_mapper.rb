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
  # @param level_field_id [String, nil] HiBob custom column ID for level ordinal
  # @return [Hash] attributes compatible with Person.new
  def self.call(employee, level_field_id: nil)
    new(employee, level_field_id: level_field_id).call
  end

  # @param employee [Hash] raw employee data from HiBob API
  # @param level_field_id [String, nil] HiBob custom column ID for level ordinal
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

    employee.dig("humanReadable", "work", "customColumns", level_field_id).to_s.strip.presence
  end

  # The site, employment and dates the Org Graph records, keyed as
  # {OrgGraph::CommandHandler#sync_person} takes them. A fact appears only when
  # the payload carries its field, so one HiBob withholds (the service user
  # can't read it) is never compared; a field it sends blank is nil. HiBob gives
  # a site no country, so country is always absent.
  #
  # @return [Hash] any of :site with :country, :fte with :employment_type,
  #   :started_on and :terminated_on
  def org_graph_facts
    facts = {}
    facts.merge!(site: label(%w[work site]), country: nil) if supplied?(%w[work site])
    if supplied?(%w[payroll employment fte]) || supplied?(%w[payroll employment type])
      facts.merge!(fte: fraction(value(%w[payroll employment fte])), employment_type: label(%w[payroll employment type]))
    end
    facts[:started_on] = value(%w[work startDate]).presence if supplied?(%w[work startDate])
    facts[:terminated_on] = value(%w[internal terminationDate]).presence if supplied?(%w[internal terminationDate])
    facts
  end

  # The list fields' item ids beside their labels, keyed like the attributes they sit
  # beside. A blank field is left out.
  #
  # @return [Hash{Symbol => ListValue}]
  def list_values
    {
      department: list_value(%w[work department]),
      job_title: list_value(%w[work title]),
      level: (list_value([ "work", "customColumns", level_field_id ]) if level_field_id.present?)
    }.compact
  end

  private

  attr_reader :employee, :level_field_id

  # Extracts the level ordinal from the HiBob custom column.
  #
  # Reads from humanReadable.work.customColumns.<level_field_id>, which
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

  # @param path [Array<String>]
  def supplied?(path)
    parent = employee.dig(*path[0..-2])
    (parent.is_a?(Hash) && parent.key?(path.last)) || employee.key?(flat_key(path))
  end

  # The machine value, from either payload shape.
  #
  # @param path [Array<String>]
  def value(path)
    parent = employee.dig(*path[0..-2])
    return parent[path.last] if parent.is_a?(Hash) && parent.key?(path.last)

    flat = employee[flat_key(path)]
    flat.is_a?(Hash) ? flat["value"] : flat
  end

  # The label HiBob shows, falling back to the machine value.
  #
  # @param path [Array<String>]
  # @return [String, nil]
  def label(path)
    (employee.dig("humanReadable", *path).presence || value(path)).to_s.strip.presence
  end

  # HiBob gives FTE as a percentage.
  #
  # @return [Float, nil]
  def fraction(percent)
    number = Float(percent.to_s, exception: false)
    number && (number / 100).round(4)
  end

  def flat_key(path) = "/#{path.join('/')}"

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
