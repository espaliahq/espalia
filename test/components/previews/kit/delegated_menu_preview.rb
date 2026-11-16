# frozen_string_literal: true

# @label Delegated menu
class Kit::DelegatedMenuPreview < Lookbook::Preview
  ROWS = [ "Backfill: Software Engineer", "New: Product Designer", "New: Data Analyst", "Backfill: Engineering Manager" ].freeze

  # One menu template serving a ⋮ on every row. Open one with a click, or with
  # Enter and then the arrow keys.
  # @param rows number
  def playground(rows: 4)
    render_with_template(template: "kit/delegated_menu_preview/rows", locals: { rows: ROWS.cycle.first(rows.to_i) })
  end

  # @!group In use

  # A list of positions, as the scenario map has it
  def list_of_positions
    render_with_template(template: "kit/delegated_menu_preview/rows", locals: { rows: ROWS })
  end

  # @!endgroup
end
