# frozen_string_literal: true

# The capability radar's data: each in-role capability placed on the role's
# ladder by its own score on the hero's scale (ADR-21), so the radar, the
# card and the hero read one number. Built from whatever the role's
# framework holds, so no count, code or ordinal is assumed.
class Assessments::CapabilityShape
  include Views::Assessments::Concerns::RatedCount

  # Levels from the radar's centre to its rim when zoomed: the zoomed level
  # sits on the middle ring, with one level either side.
  ZOOM_SPAN = 2

  # Categorical hues in the order categories take them. Red (2) is left
  # out: on the assessment page red means a rating.
  HUES = [ 1, 3, 4, 5, 7, 6, 8 ].freeze

  # A category's segment: its name, categorical `hue`, `score` (nil until
  # the coverage gate opens), scoring `state` and its {Point}s.
  Group = Data.define(:name, :hue, :score, :state, :points)

  # A capability's spoke: its 1-based `number` across the map, `reached` (a
  # ladder position from the first level met, nil when unrated or with no
  # expectation), `label` (where it stands in words), whether its binding is
  # `required`, and whether it `blocked` the score.
  Point = Data.define(:number, :stable_id, :name, :hue, :reached, :label, :required, :blocked)

  # @return [Array<String>] the ladder's level codes, lowest first
  attr_reader :codes
  # @return [Integer] the assessed level's place in {#codes}
  attr_reader :assessed_index
  # @return [Integer] the assessed level's ordinal
  attr_reader :person_level

  # @param categories [Array<Hash>] `matrix_data[:categories]`
  # @param scoring [Hash] the perspective the hero renders
  # @param merged_levels [Array<Hash>] the role's ladder, `{ ordinal:, level_code: }`
  # @param person_level [Integer] the assessed level's ordinal
  # @param context [Symbol] :self, :manager or :alignment
  # @param zoom [String, Symbol, nil] the level code to zoom to, `:all` for the
  #   whole ladder, or nil (or a code not on the ladder) for the assessed level
  def initialize(categories:, scoring:, merged_levels:, person_level:, context:, zoom: nil)
    @categories = categories
    @scoring = scoring
    @context = context
    @person_level = person_level
    @frequency_key = CONTEXT_FREQUENCY_KEYS.fetch(context, :current_frequency)
    ladder = merged_levels.sort_by { |l| l[:ordinal] }
    @codes = ladder.map { |l| l[:level_code] }
    @assessed_index = ladder.index { |l| l[:ordinal] == person_level }
    @zoom_index = (@codes.index(zoom) || @assessed_index if zoom != :all && zoomable?)
  end

  # @return [Array<Group>] framework order; none when the assessed level is
  #   not on the role's ladder
  def groups
    return @groups ||= [] unless @assessed_index

    @groups ||= begin
      number = 0
      @categories.each_with_index.map do |category_data, i|
        hue = HUES[i % HUES.size]
        points = category_data[:capabilities].map { |cap| point_for(cap, number += 1, hue) }
        Group.new(name: category_data[:category]&.name, hue: hue, score: category_score(category_data),
                  state: category_result(category_data)&.dig(:state), points: points)
      end
    end
  end

  # @return [Array<Point>] framework order
  def points = @points ||= groups.flat_map(&:points)

  # @return [Boolean] whether the ladder is long enough to zoom into
  def zoomable? = @codes.size > ZOOM_SPAN + 1

  # @return [String, nil] the level zoomed to; nil for the whole ladder
  def zoom = @zoom_index && @codes[@zoom_index]

  # @return [Range<Integer>] the places in {#codes} from the centre to the rim
  def window
    return 0..top.to_i unless @zoom_index

    centre = (@zoom_index - 1).clamp(0, @codes.size - 1 - ZOOM_SPAN)
    centre..(centre + ZOOM_SPAN)
  end

  # How far from the centre to the rim a position sits, held at the centre
  # or the rim past either edge. A one-level ladder has no climb, so it runs from none of its
  # level to all of it.
  #
  # @param position [Numeric] a ladder position, as {Point#reached}
  # @return [Float]
  def fraction(position)
    return position + 1 if top.zero?

    ((position - window.begin) / (window.end - window.begin).to_f).clamp(0.0, 1.0)
  end

  private

  def point_for(cap, number, hue)
    stable_id = cap[:capability].stable_id
    silence = unscored_label(cap)
    position = silence ? nil : position_for(stable_id)
    Point.new(number: number, stable_id: stable_id, name: cap[:capability].name, hue: hue,
              reached: position&.clamp(top.zero? ? -1.0 : 0.0, top), label: silence || label_for(position&.clamp(..top)),
              required: @scoring.dig(:capability_scores, stable_id, :required) || false,
              blocked: @scoring.dig(:capability_statuses, stable_id) == :blocked)
  end

  def top = @codes.size - 1.0

  def category_score(category_data)
    return unless category_score_unlocked?(category_data, @scoring, @context)

    category_result(category_data)[:score]
  end

  def category_result(category_data)
    @scoring.dig(:category_scores, category_data[:category]&.category_id)
  end

  # The card's two silences: no expectation at the assessed level, or none
  # of the viewer's ratings there. Either would otherwise score 0.
  def unscored_label(cap)
    return "No expectation at #{@codes[@assessed_index]}" unless
      @scoring.dig(:capability_scores, cap[:capability].stable_id, :scorable)
    return "Not rated" if cap.dig(:cells, @person_level, @frequency_key).blank?

    nil
  end

  # Ladder positions from the first level met: a score of 1.0 is the
  # assessed level met, each further 1.0 one more level. Below 0 is a share
  # of the first level.
  def position_for(stable_id)
    score = @scoring.dig(:capability_scores, stable_id, :score)
    (@assessed_index - 1 + score).round(2)
  end

  def label_for(position)
    return "#{((position + 1) * 100).round}% of #{@codes.first}" if position.negative?

    level = position.floor
    share = ((position - level) * 100).round
    share.zero? ? "#{@codes[level]} met" : "#{@codes[level]} + #{share}% to #{@codes[level + 1]}"
  end
end
