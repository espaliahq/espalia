# frozen_string_literal: true

# The scenario map's "Open position" and "Edit position" dialogs
# ([#461](https://github.com/espaliahq/espalia/issues/461)), one of each per
# map, for an editor on a scenario other than Today. A unit's "Open a
# position" button and a position's Edit… item open them, carrying what the
# form shows in `data-position-*`. Both post to {Plans::PositionsController}.
class Views::Plans::PositionDialog < Views::Base
  TITLES = { open: "Open a position", edit: "Edit position" }.freeze

  # @param mode [Symbol] :open or :edit
  # @return [String] the dialog's DOM id
  def self.dom_id_for(mode) = "#{mode}-position-modal"

  # The data the button that opens the dialog carries.
  #
  # @param mode [Symbol] :open or :edit
  # @param url [String] where the form posts
  # @param name [String] the position, or the unit it opens in
  # @param values [Hash{Symbol => Object}] each of {PositionForm::FIELDS} to show
  # @return [Hash]
  def self.trigger(mode:, url:, name:, values:)
    fields = values.slice(*Views::Plans::PositionForm::FIELDS).transform_keys { :"position_#{it}" }.transform_values(&:to_s)
    { action: "click->modal#open", modal_target_id: dom_id_for(mode), position_action: url, position_name: name, **fields }
  end

  # @param mode [Symbol] :open or :edit
  # @param form [Views::Plans::PositionForm] built with the same mode
  def initialize(mode:, form:)
    @mode = mode
    @form = form
  end

  def view_template
    render Components::Kit::Modal.new(id: self.class.dom_id_for(@mode), title: TITLES.fetch(@mode), size: :md, standalone: false) do |m|
      m.body { render @form }
    end
  end
end
