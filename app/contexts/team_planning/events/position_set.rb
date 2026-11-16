# frozen_string_literal: true

# A position a scenario opens or changes: a role and level from the framework
# in a unit, at an FTE, as a backfill or a new position. Setting a closed
# position again reopens it.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :subject_id the position id, minted by the plan
#   @option data [String] :role_id a framework role
#   @option data [String] :level_id a framework level of that role, the one pay bands key on
#   @option data [String] :unit_id an Org Graph unit, or one a plan creates
#   @option data [Float] :fte above 0 and at most 1
#   @option data [String] :basis "backfill" (committed budget) or "new" (planned)
#   @option data [String, nil] :cost_centre the position's own label, which
#     wins over its occupant's and the cost centre rules; absent from older events
#   @option data [String, nil] :hiring_status a {HIRING_STATUSES} entry; absent
#     from older events, which read as "not_started"
#   @option data [String, nil] :target_start an ISO date the seat starts on;
#     absent from older events, which have none
#   Plus {TeamPlanning::Events::Change::FIELDS}.
#
class TeamPlanning::Events::PositionSet < TeamPlanning::Events::Change
  BASES = %w[backfill new].freeze
  HIRING_STATUSES = %w[not_started recruiting on_hold offer_accepted].freeze
  IDS = %i[role_id level_id unit_id].freeze
  COST_CENTRE_LENGTH = 120

  # @return [String]
  def self.facet = "position"

  # @param data [Hash]
  # @return [Array<String>] the unit the position sits in
  def self.refers_to(data) = [ data[:unit_id] ].compact

  # @return [Boolean]
  def self.creates_subject? = true

  # @param end_state [Hash]
  # @return [Hash] the ids downcased, the FTE a Float, the cost centre squished or nil,
  #   the hiring status defaulting to "not_started" and the target start an ISO date or nil
  # @raise [TeamPlanning::Error] for a missing id, an FTE outside (0, 1], an unknown basis, a long
  #   cost centre, an unknown hiring status, a target start that isn't a date, or an accepted offer with no start
  def self.end_state(end_state)
    ids = IDS.to_h { [ it, end_state[it].to_s.strip.downcase ] }
    missing = ids.select { |_, id| id.empty? }.keys
    raise TeamPlanning::Error, "A position needs #{missing.join(", ")}" if missing.any?

    { **ids, fte: fte!(end_state[:fte]), basis: basis!(end_state[:basis]), cost_centre: cost_centre!(end_state[:cost_centre]),
      **hiring!(end_state[:hiring_status], end_state[:target_start]) }
  end

  # @param map [TeamPlanning::Baseline::Map]
  # @param data [Hash]
  # @return [TeamPlanning::Baseline::Map]
  def self.apply_to(map, data)
    fields = data.slice(*IDS, :fte, :basis, :cost_centre)
    fields[:hiring_status] = data[:hiring_status].presence || "not_started"
    fields[:target_start] = (Date.iso8601(data[:target_start]) if data[:target_start].present?)
    position = TeamPlanning::Baseline::Position.new(id: data[:subject_id], **fields, role_name: nil, level_name: nil)
    map.with(positions: map.positions.reject { it.id == position.id } + [ position ])
  end

  def self.fte!(value)
    fte = Float(value, exception: false)
    return fte if fte&.positive? && fte <= 1

    raise TeamPlanning::Error, "A position's FTE is above 0 and at most 1"
  end

  def self.basis!(value)
    basis = value.to_s.strip.downcase
    return basis if BASES.include?(basis)

    raise TeamPlanning::Error, "A position is a #{BASES.join(" or a ")} one"
  end

  def self.cost_centre!(value)
    label = value.to_s.squish.presence
    return label if label.nil? || label.length <= COST_CENTRE_LENGTH

    raise TeamPlanning::Error, "A position's cost centre is at most #{COST_CENTRE_LENGTH} characters"
  end

  def self.hiring!(status, target_start)
    status = status.to_s.strip.downcase.presence || "not_started"
    raise TeamPlanning::Error, "A position's hiring status is one of #{HIRING_STATUSES.join(", ")}" unless HIRING_STATUSES.include?(status)

    starts_on = target_start!(target_start)
    raise TeamPlanning::Error, "An accepted offer needs a target start" if status == "offer_accepted" && !starts_on

    { hiring_status: status, target_start: starts_on&.iso8601 }
  end

  def self.target_start!(value)
    return if value.blank?
    return value if value.is_a?(Date)

    Date.iso8601(value.to_s.strip)
  rescue Date::Error
    raise TeamPlanning::Error, "A position's target start is a date, such as 2026-05-01"
  end

  private_class_method :fte!, :basis!, :cost_centre!, :hiring!, :target_start!
end
