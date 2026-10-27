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
  # @param alignment_locked [Boolean] participant fully `aligned` —
  #   threaded to each {LevelChip} so residual splits render muted
  # @param assumed_below [Integer, nil] unrated cells below this ordinal
  #   paint as assumed-consistent — the lens floor (ADR-22); defaults to
  #   +person_level+
  # @param badge_label [String, nil] overrides the marked chip's badge
  def initialize(cells:, merged_levels:, capability_stable_id:, person_level:,
                 context: :self, viewer_is_manager: false, focused_ordinal: nil,
                 alignment_locked: false, assumed_below: nil, badge_label: nil)
    @assumed_below = assumed_below
    @badge_label = badge_label
    @cells = cells
    @merged_levels = merged_levels
    @capability_stable_id = capability_stable_id
    @person_level = person_level
    @context = context
    @viewer_is_manager = viewer_is_manager
    @focused_ordinal = focused_ordinal
    @alignment_locked = alignment_locked
  end

  def view_template
    # `overflow-x-auto` lets the chip strip scroll horizontally on
    # narrow viewports (the chips have `min-w-16` × N levels which
    # can exceed mobile widths). `-mx-4 px-4` extends the scroll area
    # to the card's padded edges so users can swipe to the very end.
    div(class: "overflow-x-auto -mx-4 px-4") do
      div(class: "flex gap-1 min-w-fit") do
        @merged_levels.each { |level| render chip_for(level) }
      end
    end
  end

  # One level's chip, unrendered, so a response can swap just that chip.
  #
  # @param ordinal [Integer]
  # @return [Views::Assessments::LevelChip, nil] nil when no level has it
  def chip(ordinal)
    level = @merged_levels.find { |l| l[:ordinal] == ordinal }
    chip_for(level) if level
  end

  private

  def chip_for(level)
    Views::Assessments::LevelChip.new(
      cell_data: @cells[level[:ordinal]],
      capability_stable_id: @capability_stable_id,
      ordinal: level[:ordinal],
      person_level: @person_level,
      level_code: level[:level_code],
      context: @context,
      viewer_is_manager: @viewer_is_manager,
      focused: level[:ordinal] == @focused_ordinal,
      alignment_locked: @alignment_locked,
      assumed_below: @assumed_below,
      badge_label: @badge_label
    )
  end
end
