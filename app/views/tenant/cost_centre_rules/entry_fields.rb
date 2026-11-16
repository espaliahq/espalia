# frozen_string_literal: true

# What the cost-centre entry pages share: the fields that make an entry, and
# the words for what one matches.
module Views::Tenant::CostCentreRules::EntryFields
  # The units, roles and countries the pickers offer, and that name an entry.
  Choices = Data.define(:units, :roles, :countries, :unit_names, :role_names, :family_names) do
    # @param units [Array<OrgUnit>]
    # @param roles [Array<FrameworkState::Role>] with their levels and families loaded
    # @param countries [Array<String>]
    def self.from(units:, roles:, countries:)
      new(units:, roles:, countries:, unit_names: units.to_h { [ it.id, it.name ] }, role_names: roles.to_h { [ it.role_id, it.name ] },
          family_names: roles.filter_map(&:role_family).to_h { [ it.role_family_id, it.name ] })
    end
  end

  ANY_UNIT = "Any unit"
  EVERY_ROLE = "Every role"
  EVERY_LEVEL = "Every level"

  # @param entries [Array<Hash>]
  # @return [String] a short fingerprint of the list, so a write can tell the page showed the list as it stands
  def self.version(entries) = Digest::SHA256.hexdigest(entries.to_json).first(16)

  # @param entry [Hash] as stored
  # @return [Hash{Symbol => String}] the entry as the form holds it
  def self.form_values(entry)
    reach = ("role:#{entry['role_id']}" if entry["role_id"]) || ("family:#{entry['role_family_id']}" if entry["role_family_id"])
    { unit_id: entry["unit_id"], reach:, level_ordinal: entry["level_ordinal"]&.to_s, location: entry["location"],
      cost_centre: entry["cost_centre"] }
  end

  private

  # @param entry [Hash] as stored
  # @return [String] what it matches, such as "Payments and below · Every role in Engineering · Level 3"
  def matcher_text(entry)
    [ (unit_name(entry["unit_id"]) if entry["unit_id"]),
      (role_name(entry["role_id"]) if entry["role_id"]),
      (family_name(entry["role_family_id"]) if entry["role_family_id"]),
      ("Level #{entry['level_ordinal']}" if entry["level_ordinal"]),
      entry["location"] ].compact.join(" · ")
  end

  def unit_name(id) = @choices.unit_names[id]&.then { "#{it} and below" } || "A unit no longer in the Org Graph"
  def role_name(id) = @choices.role_names[id] || "A role no longer in the framework"
  def family_name(id) = @choices.family_names[id]&.then { "Every role in #{it}" } || "A role family no longer in the framework"

  # @return [Boolean] whether a unit, role or family the entry names has gone
  def gone?(entry)
    (entry["unit_id"] && !@choices.unit_names.key?(entry["unit_id"])) ||
      (entry["role_id"] && !@choices.role_names.key?(entry["role_id"])) ||
      (entry["role_family_id"] && !@choices.family_names.key?(entry["role_family_id"]))
  end

  # @param values [Hash{Symbol => String}] what the form holds
  def entry_fields(values)
    div(class: "grid gap-4 sm:grid-cols-2") do
      field("cost-centre-entry-unit", "Unit", hint: "It covers the units below it too.") { unit_select(values) }
      field("cost-centre-entry-reach", "Who") { reach_select(values) }
      field("cost-centre-entry-level", "Level", hint: "A level number, in any role.") { level_select(values) }
      field("cost-centre-entry-location", "Country", hint: "Leave it blank for any country. Open positions have none.") do
        input(id: "cost-centre-entry-location", name: "entry[location]", type: "text", list: "cost-centre-entry-countries",
              value: values[:location], autocomplete: "off", class: Components::Kit::Field::INPUT,
              aria: { describedby: "cost-centre-entry-location-hint" })
        datalist(id: "cost-centre-entry-countries") { @choices.countries.each { |country| option(value: country) } }
      end
    end
    field("cost-centre-entry-label", "Cost centre") do
      input(id: "cost-centre-entry-label", name: "entry[cost_centre]", type: "text", required: true,
            maxlength: TeamPlanning::Events::PositionSet::COST_CENTRE_LENGTH, value: values[:cost_centre],
            autocomplete: "off", class: Components::Kit::Field::INPUT)
    end
  end

  def field(id, label_text, hint: nil, &)
    div(class: "space-y-1") do
      label(for: id, class: "block text-sm font-medium text-default") { label_text }
      yield
      p(id: "#{id}-hint", class: "text-xs text-muted") { hint } if hint
    end
  end

  def unit_select(values)
    select(id: "cost-centre-entry-unit", name: "entry[unit_id]", class: Components::Kit::Field::SELECT,
           aria: { describedby: "cost-centre-entry-unit-hint" }) do
      option(value: "", selected: values[:unit_id].blank?) { ANY_UNIT }
      offered = @choices.units.reject(&:retired?)
      kept_option(values[:unit_id], offered.map(&:id)) { unit_name(values[:unit_id]) }
      offered.each { |unit| option(value: unit.id, selected: values[:unit_id] == unit.id) { unit.name } }
    end
  end

  def reach_select(values)
    select(id: "cost-centre-entry-reach", name: "entry[reach]", class: Components::Kit::Field::SELECT) do
      option(value: "", selected: values[:reach].blank?) { EVERY_ROLE }
      kept_option(values[:reach], reaches) { values[:reach].start_with?("role:") ? role_name(nil) : family_name(nil) }
      @choices.roles.group_by(&:role_family).sort_by { |family, _| [ family ? 0 : 1, family&.name.to_s ] }.each do |family, roles|
        optgroup(label: family&.name.presence || "Roles in no family") do
          reach_option(values, "family:#{family.role_family_id}", "Every role in #{family.name}") if family
          roles.each { |role| reach_option(values, "role:#{role.role_id}", role.name) }
        end
      end
    end
  end

  def reach_option(values, value, text) = option(value:, selected: values[:reach] == value) { text }

  def reaches
    @choices.roles.flat_map { |role| [ "role:#{role.role_id}", ("family:#{role.role_family.role_family_id}" if role.role_family) ] }.compact
  end

  # Keeps a saved value the picker no longer offers, so saving another field
  # can't quietly widen the entry to match everything.
  def kept_option(value, offered, &)
    option(value:, selected: true, &) if value.present? && !offered.include?(value)
  end

  def level_select(values)
    top = @choices.roles.flat_map(&:levels).map(&:ordinal).max.to_i
    select(id: "cost-centre-entry-level", name: "entry[level_ordinal]", class: Components::Kit::Field::SELECT,
           aria: { describedby: "cost-centre-entry-level-hint" }) do
      option(value: "", selected: values[:level_ordinal].blank?) { EVERY_LEVEL }
      kept_option(values[:level_ordinal].to_s, (1..top).map(&:to_s)) { "Level #{values[:level_ordinal]}" }
      (1..top).each { |ordinal| option(value: ordinal, selected: values[:level_ordinal].to_s == ordinal.to_s) { "Level #{ordinal}" } }
    end
  end
end
