# frozen_string_literal: true

# The form inside {PositionDialog}, for opening a position in a unit or
# editing one ([#461](https://github.com/espaliahq/espalia/issues/461)). The
# `position-form` controller fills it from the button that opened the
# dialog. A refused save renders it again in place, with what was typed and
# why, so {Plans::PositionsController} renders this class on its own.
#
# The edit form carries each field's value as it was opened in `original[…]`,
# so the controller sends only the fields the editor changed, and an edit
# made meanwhile to another field survives.
class Views::Plans::PositionForm < Views::Base
  FIELDS = %i[unit_id level_id fte basis cost_centre].freeze
  BASES = { "backfill" => "Backfill: committed budget", "new" => "New: planned budget" }.freeze

  # @param mode [Symbol] :open or :edit
  # @return [String] the form's DOM id
  def self.dom_id_for(mode) = "#{mode}-position-form"

  # @param mode [Symbol] :open or :edit
  # @param scenario_id [String]
  # @param scenario_name [String]
  # @param units [Array<Array(Hash, Array<String>)>] each unit with the names above it, in map order
  # @param roles [Array<FrameworkState::Role>] with their levels
  # @param action [String, nil] where it posts; the opening button sets it
  # @param values [Hash{Symbol => String}] what to show in each field
  # @param original [Hash{Symbol => String}] each field as the edit opened it
  # @param name [String, nil] the position, or the unit it opens in
  # @param error [String, nil] why the last save was refused
  def initialize(mode:, scenario_id:, scenario_name:, units:, roles:, action: nil, values: {}, original: {}, name: nil, error: nil)
    @mode = mode
    @scenario_id = scenario_id
    @scenario_name = scenario_name
    @units = units
    @roles = roles
    @action = action
    @values = values
    @original = original
    @name = name
    @error = error
  end

  def view_template
    form(id: self.class.dom_id_for(@mode), action: @action, method: "post", class: "space-y-4",
         data: { controller: "position-form", position_form_mode_value: @mode.to_s, action: "turbo:submit-end->modal#submitted" }) do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      input(type: "hidden", name: "_method", value: "patch") if edit?
      input(type: "hidden", name: "position[scenario_id]", value: @scenario_id)
      render(Components::Kit::Alert.new(tone: :danger, role: "alert", title: "Couldn't save the position")) { @error } if @error
      intro
      edit? ? unit_select : unit_line
      level_select
      fte_field
      basis_field
      cost_centre_field
      originals if edit?
      actions
    end
  end

  private

  def edit? = @mode == :edit

  def id(field) = "#{@mode}-position-#{field.to_s.dasherize}"

  def intro
    p(class: "text-sm text-muted") do
      plain(edit? ? "Editing " : "Opening a position in ")
      strong(class: "text-default", data: { position_form_target: "name" }) { @name }
      plain " in "
      strong(class: "text-default") { @scenario_name }
      plain "."
    end
  end

  # Opening a position puts it in the unit whose button was pressed.
  def unit_line
    input(type: "hidden", name: "position[unit_id]", value: @values[:unit_id], data: { position_form_target: "unit_id" })
  end

  def unit_select
    field(:unit_id, "Unit") do
      select(id: id(:unit_id), name: "position[unit_id]", class: Components::Kit::Field::SELECT, data: { position_form_target: "unit_id" }) do
        @units.each { |unit, path| option(value: unit[:id], selected: @values[:unit_id] == unit[:id]) { (path + [ unit[:name] ]).join(" › ") } }
      end
    end
  end

  # One select, a group per role, so a level can only be one of its role's.
  def level_select
    field(:level_id, "Role and level") do
      select(id: id(:level_id), name: "position[level_id]", required: true, class: Components::Kit::Field::SELECT,
             data: { position_form_target: "level_id" }) do
        option(value: "", selected: @values[:level_id].blank?) { "Choose a role and level" }
        @roles.each do |role|
          optgroup(label: role.name) do
            role.levels.sort_by(&:ordinal).each do |level|
              option(value: level.level_id, selected: @values[:level_id] == level.level_id) { "#{role.name}, #{"#{level.code} #{level.title}".strip}" }
            end
          end
        end
      end
    end
  end

  def fte_field
    field(:fte, "FTE", hint: "Above 0 and at most 1, such as 0.5 for half time.") do
      input(id: id(:fte), name: "position[fte]", type: "number", min: "0", max: "1", step: "any", required: true,
            value: @values[:fte] || "1", inputmode: "decimal", class: Components::Kit::Field::INPUT,
            aria: { describedby: "#{id(:fte)}-hint" }, data: { position_form_target: "fte" })
    end
  end

  def basis_field
    fieldset do
      legend(class: "block text-sm font-medium text-default mb-1") { "Budget" }
      div(class: "space-y-1") do
        BASES.each do |value, label|
          label(class: "flex items-center gap-2 text-sm text-default") do
            input(type: "radio", name: "position[basis]", value:, checked: (@values[:basis] || "new") == value,
                  class: Components::Kit::Field::RADIO, data: { position_form_target: "basis" })
            plain label
          end
        end
      end
    end
  end

  def cost_centre_field
    field(:cost_centre, "Cost centre", hint: "Leave it blank to let the cost centre entries decide.") do
      input(id: id(:cost_centre), name: "position[cost_centre]", type: "text", maxlength: TeamPlanning::Events::PositionSet::COST_CENTRE_LENGTH,
            value: @values[:cost_centre], autocomplete: "off", class: Components::Kit::Field::INPUT,
            aria: { describedby: "#{id(:cost_centre)}-hint" }, data: { position_form_target: "cost_centre" })
    end
  end

  def originals
    FIELDS.each do |field|
      input(type: "hidden", name: "original[#{field}]", value: @original[field], data: { position_form_target: "original", field: field.to_s })
    end
  end

  def actions
    div(class: "flex items-center gap-3") do
      render Components::Kit::Button.new(tone: :brand, type: :submit) { edit? ? "Save position" : "Open position" }
      render Components::Kit::Button.new(variant: :outline, data: { action: "click->modal#close" }) { "Cancel" }
    end
  end

  def field(name, label_text, hint: nil, &)
    div do
      label(for: id(name), class: "block text-sm font-medium text-default mb-1") { label_text }
      yield
      p(id: "#{id(name)}-hint", class: "mt-1 text-xs text-muted") { hint } if hint
    end
  end
end
