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
  # @param mapped_fields [Hash{String => String}] the field the tenant's mapping
  #   names for each part of a fact, as {OrgFactProvider.fields_for} gives them
  def initialize(employee, level_field_id: nil, mapped_fields: {})
    @employee = employee
    @level_field_id = level_field_id
    @mapped_fields = mapped_fields.transform_keys(&:to_s)
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

  # The site, cost centre, employment and dates the Org Graph records, keyed as
  # {OrgGraph::CommandHandler#sync_person} takes them. A fact appears only when
  # the payload carries its field, so one HiBob withholds (the service user
  # can't read it) is never compared. A pair travels together, so FTE and type
  # are written only when both arrive, and so are a site and a mapped country.
  # A field it sends blank, or a value the Org Graph can't hold (an FTE outside
  # 1–100, a date that isn't ISO 8601), is nil. HiBob gives a site no country,
  # so country is nil until the mapping names a field for it, and cost centre
  # is absent until the mapping names its field.
  #
  # @return [Hash] any of :site with :country, :cost_centre, :fte with
  #   :employment_type, :started_on and :terminated_on
  def org_graph_facts
    facts = {}
    country = mapped_path("country")
    if supplied?(%w[work site]) && (country.nil? || supplied?(country))
      facts.merge!(site: label(%w[work site]), country: (label(country) if country))
    end
    cost_centre = mapped_path("cost_centre")
    facts[:cost_centre] = label(cost_centre) if cost_centre && supplied?(cost_centre)
    if supplied?(%w[payroll employment fte]) && supplied?(%w[payroll employment type])
      facts.merge!(fte: fraction(value(%w[payroll employment fte])),
        employment_type: human_readable(%w[payroll employment type]))
    end
    facts[:started_on] = iso_date(value(%w[work startDate])) if supplied?(%w[work startDate])
    facts[:terminated_on] = iso_date(value(%w[internal terminationDate])) if supplied?(%w[internal terminationDate])
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
      level: (list_value(level_path) if level_field_id.present?)
    }.compact
  end

  private

  attr_reader :employee, :level_field_id, :mapped_fields

  def level_path = path_of(level_field_id)

  # @return [Array<String>, nil]
  def mapped_path(part)
    path_of(mapped_fields[part]) if mapped_fields[part].present?
  end

  # HiBob returns root fields (`root.email`) at the top level, not under `root`.
  def path_of(field_id) = Hris::Hibob::Client.field_path(field_id).delete_prefix("root.").split(".")

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
    id = value(path).presence
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
    (human_readable(path) || value(path)).to_s.strip.presence
  end

  # A list field's machine value is an item id, so its label comes only from here.
  #
  # @param path [Array<String>]
  # @return [String, nil]
  def human_readable(path)
    employee.dig("humanReadable", *path).to_s.strip.presence
  end

  # HiBob gives FTE as a percentage.
  #
  # @return [Float, nil]
  def fraction(percent)
    number = Float(percent.to_s, exception: false)
    return nil unless number && number <= 100

    fraction = (number / 100).round(4)
    fraction if fraction.positive?
  end

  # @return [String, nil]
  def iso_date(raw)
    Date.iso8601(raw.to_s).iso8601 if raw.present?
  rescue Date::Error
    nil
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
