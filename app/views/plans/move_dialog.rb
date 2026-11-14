# frozen_string_literal: true

# The scenario map's "Move" dialog ([#285](https://github.com/espaliahq/espalia/issues/285)), one per map, for an editor on a
# scenario other than Today. Each person row's "Move…" button opens it, and a
# drop on a unit clicks that same button with the unit in `data-move-to`, so
# drag and keyboard share one path. The `move-form` controller fills it from
# the trigger, and it posts to {Plans::AssignmentsController}.
class Views::Plans::MoveDialog < Views::Base
  ID = "move-person-modal"
  UNASSIGNED = Operations::TeamPlanning::MovePlace::UNASSIGNED

  # The data a person row's "Move…" button carries.
  #
  # @param url [String] the person's assignment path
  # @param name [String] the person's name
  # @param from [String] the unit their place is in, or "unassigned"
  # @param place [Hash, nil] the place moved: its position and role
  # @param share [Rational, nil] what the place counts for; the new place starts at it
  # @return [Hash]
  def self.trigger(url:, name:, from:, place:, share: nil)
    { action: "click->modal#open", modal_target_id: ID, move_action: url, move_name: name, move_from: from,
      move_from_position: place&.dig(:position_id).to_s, move_role: place&.dig(:role).to_s, move_allocation: percent(share) }
  end

  # @param share [Rational, nil]
  # @return [String] the share as a percent, or 100 when there is none to keep
  def self.percent(share)
    return "100" unless share&.positive?

    value = (share * 100).to_f.round(1)
    (value % 1).zero? ? value.to_i.to_s : value.to_s
  end

  # @param scenario_id [String]
  # @param scenario_name [String]
  # @param units [Array<Array(Hash, Array<String>)>] each unit with the names above it, in map order
  def initialize(scenario_id:, scenario_name:, units:)
    @scenario_id = scenario_id
    @scenario_name = scenario_name
    @units = units
  end

  def view_template
    render Components::Kit::Modal.new(id: ID, title: "Move", size: :sm, standalone: false) do |m|
      m.body { move_form }
    end
  end

  private

  def move_form
    form(method: "post", class: "space-y-4",
         data: { controller: "move-form", move_form_unassigned_value: UNASSIGNED, action: "turbo:submit-end->modal#submitted" }) do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      input(type: "hidden", name: "_method", value: "patch")
      input(type: "hidden", name: "move[scenario_id]", value: @scenario_id)
      input(type: "hidden", name: "move[from_unit_id]", data: { move_form_target: "from" })
      input(type: "hidden", name: "move[from_position_id]", data: { move_form_target: "fromPosition" })
      p(class: "text-sm text-muted") do
        plain "Moving "
        strong(class: "text-default", data: { move_form_target: "name" })
        plain " in "
        strong(class: "text-default") { @scenario_name }
        plain ". Their other places stay as they are, except one they already hold in the unit they move to, which this replaces."
      end
      field("move-to", "To") { to_select }
      div(class: "grid grid-cols-2 gap-3", data: { move_form_target: "placeFields" }) do
        field("move-allocation", "Allocation (%)") do
          input(id: "move-allocation", type: "number", name: "move[allocation]", min: "0.1", max: 100, step: "any", required: true,
                class: Components::Kit::Field::INPUT, data: { move_form_target: "allocation" })
        end
        field("move-role", "Role") do
          input(id: "move-role", type: "text", name: "move[role]", autocomplete: "off", placeholder: "Optional",
                class: Components::Kit::Field::INPUT, data: { move_form_target: "role" })
        end
      end
      div(class: "flex items-center gap-3") do
        render Components::Kit::Button.new(tone: :brand, type: :submit) { "Save move" }
        render Components::Kit::Button.new(variant: :outline, data: { action: "click->modal#close" }) { "Cancel" }
      end
    end
  end

  def to_select
    select(id: "move-to", name: "move[to_unit_id]", class: Components::Kit::Field::SELECT,
           data: { move_form_target: "to", action: "change->move-form#sync" }) do
      @units.each { |unit, path| option(value: unit[:id]) { (path + [ unit[:name] ]).join(" › ") } }
      option(value: UNASSIGNED) { "Unassigned" }
    end
  end

  def field(id, text)
    div do
      label(for: id, class: "block text-sm font-medium text-default mb-1") { text }
      yield
    end
  end
end
