# frozen_string_literal: true

# Greedy lane packing for initialed dots on a calibration axis (Score by
# cohort, the drill-in's per-level frequency axes): each mark, taken in
# position order, joins the first lane whose last occupant is at least
# `nudge` away, so a cluster stacks downward instead of piling up and the
# 44px tap targets never cover one another.
module Views::CalibrationSessions::LanePacking
  # @param items [Array] already sorted by position
  # @param nudge [Numeric] the closest two marks may sit and share a lane,
  #   in the same units the block returns
  # @param max_lanes [Integer, nil] nil stacks as deep as the cluster needs
  # @yieldparam item [Object]
  # @yieldreturn [Numeric] the item's RENDERED position
  # @return [Array<Array(Object, Integer)>] `[item, lane]` pairs
  def pack_lanes(items, nudge:, max_lanes: nil)
    lane_edges = []
    items.map do |item|
      position = yield(item)
      lane = lane_edges.index { |edge| (position - edge).abs >= nudge }
      lane ||= max_lanes.nil? || lane_edges.size < max_lanes ? lane_edges.size : (position.round % max_lanes)
      lane_edges[lane] = position
      [ item, lane ]
    end
  end
end
