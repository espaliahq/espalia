# frozen_string_literal: true

# A split whose agreed part couldn't stand without the rest: a change moving
# across needs something only a staying change creates.
class TeamPlanning::SplitBlocked < TeamPlanning::Error
  Block = Data.define(:event_id, :subject_id, :facet, :blocks_event_id)

  attr_reader :blocks

  # @param blocks [Array<Block>] each staying change, with the moving change that needs it
  def initialize(blocks)
    @blocks = blocks
    super("The agreed part can't stand without #{blocks.size == 1 ? "a change" : "#{blocks.size} changes"} " \
          "that stay#{blocks.size == 1 ? "s" : ""}: #{blocks.map { "#{it.facet} of #{it.subject_id}" }.uniq.join(", ")}. " \
          "Move #{blocks.size == 1 ? "it" : "them"} across too")
  end
end
