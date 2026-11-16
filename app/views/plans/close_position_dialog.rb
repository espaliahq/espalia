# frozen_string_literal: true

# The scenario map's "Close position" dialog
# ([#461](https://github.com/espaliahq/espalia/issues/461)), one per map. A
# position's Close… item opens it, carrying the position's name and who is in
# it, so the dialog can say what stays behind before anyone confirms.
class Views::Plans::ClosePositionDialog < Views::Base
  ID = "close-position-modal"

  # @param url [String] the position's path
  # @param name [String] what the map calls the position
  # @param occupants [Array<String>] the names of the people in it
  # @return [Hash]
  def self.trigger(url:, name:, occupants:)
    { action: "click->modal#open", modal_target_id: ID, close_action: url, close_name: name, close_occupants: occupants.to_sentence }
  end

  # @param scenario_id [String]
  # @param scenario_name [String]
  def initialize(scenario_id:, scenario_name:)
    @scenario_id = scenario_id
    @scenario_name = scenario_name
  end

  def view_template
    render Components::Kit::Modal.new(id: ID, title: "Close position", size: :sm, standalone: false) do |m|
      m.body { close_form }
    end
  end

  private

  def close_form
    form(method: "post", class: "space-y-4", data: { controller: "close-position-form", action: "turbo:submit-end->modal#submitted" }) do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      input(type: "hidden", name: "_method", value: "delete")
      input(type: "hidden", name: "scenario_id", value: @scenario_id)
      p(class: "text-sm text-muted") do
        plain "Closing "
        strong(class: "text-default", data: { close_position_form_target: "name" })
        plain " in "
        strong(class: "text-default") { @scenario_name }
        plain "."
      end
      ul(class: "list-disc space-y-1 pl-5 text-sm text-muted") do
        li(data: { close_position_form_target: "occupants" }, hidden: true) do
          strong(class: "text-default", data: { close_position_form_target: "occupantNames" })
          plain " stay placed in it until you move them."
        end
        li { "Funding set on a budget line for it stays until you change it." }
        li { "Checks will list what it leaves behind, and you can undo the close from Changes." }
      end
      div(class: "flex items-center gap-3") do
        render Components::Kit::Button.new(tone: :danger, type: :submit) { "Close position" }
        render Components::Kit::Button.new(variant: :outline, data: { action: "click->modal#close" }) { "Cancel" }
      end
    end
  end
end
