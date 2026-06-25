# frozen_string_literal: true

# Horizontal strip of level chips for a single capability.
#
# Renders one LevelChip per merged level. Divergence between the primary
# and secondary perspectives is signalled by a dot on the chip itself
# (see {LevelChip#divergence_dot}); the full per-perspective values are
# available in the expansion panel.
#
class Views::Assessments::LevelStrip < Views::Base
  # @param cells [Hash<Integer, Hash>] from MatrixDataBuilder
  # @param merged_levels [Array<Hash>]
  # @param capability_stable_id [String]
  # @param person_level [Integer]
  # @param context [Symbol] :self, :manager, or :alignment
  # @param viewer_is_manager [Boolean] viewer is the manager-side party
  #   (threaded to each {LevelChip} for the split-corner ordering)
  # @param focused_ordinal [Integer, nil] currently focused level ordinal
  def initialize(cells:, merged_levels:, capability_stable_id:, person_level:,
                 context: :self, viewer_is_manager: false, focused_ordinal: nil)
    @cells = cells
    @merged_levels = merged_levels
    @capability_stable_id = capability_stable_id
    @person_level = person_level
    @context = context
    @viewer_is_manager = viewer_is_manager
    @focused_ordinal = focused_ordinal
  end

  def view_template
    # `overflow-x-auto` lets the chip strip scroll horizontally on
    # narrow viewports (the chips have `min-w-[60px]` × N levels which
    # can exceed mobile widths). `-mx-4 px-4` extends the scroll area
    # to the card's padded edges so users can swipe to the very end.
    div(class: "overflow-x-auto -mx-4 px-4") do
      div(class: "flex gap-1 min-w-fit") do
        @merged_levels.each do |level|
          render Views::Assessments::LevelChip.new(
            cell_data: @cells[level[:ordinal]],
            capability_stable_id: @capability_stable_id,
            ordinal: level[:ordinal],
            person_level: @person_level,
            level_code: level[:level_code],
            context: @context,
            viewer_is_manager: @viewer_is_manager,
            focused: level[:ordinal] == @focused_ordinal
          )
        end
      end
    end
  end
end
