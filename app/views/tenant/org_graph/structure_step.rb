# frozen_string_literal: true

# What the drawer's structure steps share (#494): giving a unit a structure
# of its own, withdrawing it, and moving a unit into one. Each changes the
# type of every unit it covers, so each asks what each type becomes.
class Views::Tenant::OrgGraph::StructureStep < Views::Tenant::OrgGraph::UnitStep
  # @param overview [OrgGraph::UnitsOverview]
  # @param structure_unit_id [String, nil] nil for the top structure
  # @return [String] "the top structure", or "Payments's structure"
  def self.structure_name(overview, structure_unit_id)
    return I18n.t("org_graph.structure_name.top") unless structure_unit_id

    I18n.t("org_graph.structure_name.unit", unit: overview.unit(structure_unit_id).name)
  end

  private

  # A structure sits over sub-units, and an HRIS may supply the unit that
  # declares one, so the reshape blockers don't apply.
  def blocked_because
    return "Only an admin can change a unit's structure." unless @rights.structure?

    not_allowed_because unless allowed?
  end

  def structure_name(structure_unit_id) = self.class.structure_name(@overview, structure_unit_id)

  def warning(id, text) = render(Components::Kit::Alert.new(tone: :warning, id:)) { text }

  # How many units change type in all, said just before the button.
  def change_count(units)
    p(id: "org-unit-structure-count", class: "text-sm font-medium text-default") do
      units.one? ? "1 unit changes type." : "#{units.size} units change type."
    end
  end

  # @param units [Array<OrgUnit>] the units whose types change
  # @return [Array<OrgTaxonomyLevel>] the types they hold, top first
  def held_types(units)
    held = units.map(&:level_id).uniq
    @overview.all_levels.select { held.include?(it.id) }
  end

  def count_of(units, type) = units.count { it.level_id == type.id }

  # One row per type held: what it is now, and the field that says what it becomes.
  def conversion_fieldset(units, legend_text)
    fieldset(class: "space-y-3") do
      legend(class: "text-sm font-medium text-default") { legend_text }
      held_types(units).each do |type|
        id = "org-unit-convert-#{type.id}"
        div(class: "grid grid-cols-1 gap-1 sm:grid-cols-[1fr_14rem] sm:items-center sm:gap-3") do
          label(for: id, class: "text-sm text-default") do
            plain type.name
            count = count_of(units, type)
            span(class: "text-muted") { " (#{count} #{'unit'.pluralize(count)})" }
          end
          yield type, id
        end
      end
    end
  end

  def type_select(name, id, kinds, selected:)
    select(id:, name:, required: true, class: "#{Components::Kit::Field::SELECT} w-full") do
      kinds.each { |kind| option(value: kind.id, selected: kind.id == selected) { kind.name } }
    end
  end

  # The type of the same name, ignoring case, when there is one.
  def same_name(type, kinds) = kinds.find { it.name.casecmp?(type.name) }&.id
end
