# frozen_string_literal: true

# The labelled fields a budget line's add and change forms share.
module Views::Tenant::BudgetLines::LineFields
  PERIOD_LABELS = { "year" => "A year", "month" => "A month" }.freeze

  private

  # @param values [Hash] what the form shows: a line's payload, or what was typed
  # @param roles [Array<FrameworkState::Role>] with their levels
  # @param countries [Array<String>]
  # @param money [Boolean] false leaves out amount, currency and period, which a member without the see-pay right
  #   may not set ([#367](https://github.com/espaliahq/espalia/issues/367))
  def line_fields(values, roles:, countries:, money: true)
    div(class: "grid gap-4 sm:grid-cols-2") do
      date_field(:starts_on, "Starts on", values)
      date_field(:ends_on, "Ends on", values)
    end
    div(class: "grid gap-4 sm:grid-cols-2") do
      field("budget-line-origin", "Origin") do
        select(id: "budget-line-origin", name: "budget_line[origin]", required: true, class: Components::Kit::Field::SELECT) do
          Views::Tenant::BudgetLines::LineText::ORIGINS.each do |value, label|
            option(value:, selected: (values[:origin] || "new") == value) { label }
          end
        end
      end
      date_field(:approved_on, "Approved on", values, required: false, hint: "For a new position. Leave it blank if you don't know.")
    end
    money ? money_fields(values) : div(class: "grid gap-4 sm:grid-cols-4") { text_field(:head_count, "Head count", values, inputmode: "decimal") }
    div(class: "grid gap-4 sm:grid-cols-2") do
      field("budget-line-position", "Role and level", hint: "Leave it as any role for a line not tied to one.") do
        position_select(values, roles)
      end
      field("budget-line-location", "Country", hint: "Leave it blank for any country.") do
        input(id: "budget-line-location", name: "budget_line[location]", type: "text", list: "budget-line-countries",
              value: values[:location], autocomplete: "off", class: Components::Kit::Field::INPUT,
              aria: { describedby: "budget-line-location-hint" })
        datalist(id: "budget-line-countries") { countries.each { option(value: it) } }
      end
    end
    field("budget-line-cost-centre", "Cost centre", hint: "The label the Org Graph uses, if the line names one.") do
      input(id: "budget-line-cost-centre", name: "budget_line[cost_centre]", type: "text", value: values[:cost_centre],
            autocomplete: "off", class: Components::Kit::Field::INPUT, aria: { describedby: "budget-line-cost-centre-hint" })
    end
  end

  def money_fields(values)
    div(class: "grid gap-4 sm:grid-cols-4") do
      text_field(:amount, "Amount", values, inputmode: "decimal", hint: "Leave it blank for a head count alone.")
      text_field(:currency, "Currency", values, maxlength: 3, extra: "uppercase", hint: "Such as AUD.")
      field("budget-line-period", "Per") do
        select(id: "budget-line-period", name: "budget_line[period]", class: Components::Kit::Field::SELECT) do
          PERIOD_LABELS.each { |value, label| option(value:, selected: (values[:period] || "year") == value) { label } }
        end
      end
      text_field(:head_count, "Head count", values, inputmode: "decimal")
    end
  end

  # One picker for both, as a line names a role, one of its levels, or neither.
  # A line keeps the role and level it was approved for after they leave the framework, so its form offers them too.
  def departed_option(chosen, values, roles)
    offered = roles.flat_map { |role| [ "role:#{role.role_id}", *role.levels.map { "level:#{it.level_id}" } ] }
    return if chosen.blank? || offered.include?(chosen) || values[:role].blank?

    label = [ values[:role], values[:level_name] ].compact_blank.join(", ")
    option(value: chosen, selected: true) { "#{label} (no longer in the framework)" }
  end

  def position_select(values, roles)
    chosen = values[:position] || (values[:level_id] ? "level:#{values[:level_id]}" : values[:role_id] && "role:#{values[:role_id]}")
    select(id: "budget-line-position", name: "budget_line[position]", class: Components::Kit::Field::SELECT,
           aria: { describedby: "budget-line-position-hint" }) do
      option(value: "") { "Any role" }
      departed_option(chosen, values, roles)
      roles.each do |role|
        optgroup(label: role.name) do
          option(value: "role:#{role.role_id}", selected: chosen == "role:#{role.role_id}") { "Any #{role.name} level" }
          role.levels.sort_by(&:ordinal).each do |level|
            option(value: "level:#{level.level_id}", selected: chosen == "level:#{level.level_id}") { "#{level.code} #{level.title}".strip }
          end
        end
      end
    end
  end

  def date_field(name, label_text, values, required: true, hint: nil)
    id = "budget-line-#{name.to_s.dasherize}"
    field(id, label_text, hint:) do
      input(id:, name: "budget_line[#{name}]", type: "date", required:, value: values[name],
            class: Components::Kit::Field::INPUT, aria: { describedby: ("#{id}-hint" if hint) })
    end
  end

  def text_field(name, label_text, values, hint: nil, extra: nil, **attributes)
    id = "budget-line-#{name.to_s.dasherize}"
    field(id, label_text, hint:) do
      input(id:, name: "budget_line[#{name}]", type: "text", value: values[name], autocomplete: "off",
            class: [ Components::Kit::Field::INPUT, extra ].compact.join(" "), aria: { describedby: ("#{id}-hint" if hint) }, **attributes)
    end
  end

  def field(id, label_text, hint: nil, &)
    div do
      label(for: id, class: "block text-sm font-medium text-default mb-1") { label_text }
      yield
      p(id: "#{id}-hint", class: "mt-1 text-xs text-muted") { hint } if hint
    end
  end
end
