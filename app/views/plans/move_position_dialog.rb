# frozen_string_literal: true

# The scenario map's "Move position" dialog ([#285](https://github.com/espaliahq/espalia/issues/285)), one per map, for an
# editor on a scenario other than Today. Each position's "Move…" button opens
# it, and a drop on a unit clicks that button with the unit in `data-move-to`,
# as {MoveDialog} does for people. It posts to {Plans::PositionsController}.
class Views::Plans::MovePositionDialog < Views::Base
  ID = "move-position-modal"

  # The data a position's "Move…" button carries.
  #
  # @param url [String] the position's path
  # @param name [String] what the map calls the position
  # @param from [String] the unit it is in
  # @return [Hash]
  def self.trigger(url:, name:, from:)
    { action: "click->modal#open", modal_target_id: ID, move_action: url, move_name: name, move_from: from }
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
    render Components::Kit::Modal.new(id: ID, title: "Move position", size: :sm, standalone: false) do |m|
      m.body { move_form }
    end
  end

  private

  def move_form
    form(method: "post", class: "space-y-4", data: { controller: "move-form", action: "turbo:submit-end->modal#submitted" }) do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      input(type: "hidden", name: "_method", value: "patch")
      input(type: "hidden", name: "move[scenario_id]", value: @scenario_id)
      p(class: "text-sm text-muted") do
        plain "Moving "
        strong(class: "text-default", data: { move_form_target: "name" })
        plain " in "
        strong(class: "text-default") { @scenario_name }
        plain ". The people in it move with it, and their reporting lines stay as they are."
      end
      div do
        label(for: "move-position-to", class: "block text-sm font-medium text-default mb-1") { "To" }
        select(id: "move-position-to", name: "move[to_unit_id]", class: Components::Kit::Field::SELECT, data: { move_form_target: "to" }) do
          @units.each { |unit, path| option(value: unit[:id]) { (path + [ unit[:name] ]).join(" › ") } }
        end
      end
      div(class: "flex items-center gap-3") do
        render Components::Kit::Button.new(tone: :brand, type: :submit) { "Save move" }
        render Components::Kit::Button.new(variant: :outline, data: { action: "click->modal#close" }) { "Cancel" }
      end
    end
  end
end
