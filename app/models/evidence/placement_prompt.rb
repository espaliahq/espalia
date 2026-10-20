# frozen_string_literal: true

# What the model sees when it suggests where a piece of feedback belongs, and
# the only cells it may answer with.
#
# The candidates are the cells the recipient's role reads
# ({Evidence::FrameworkCellOptions#expectation_map}, so a suggested cell always
# exists and the evidence modal can show it) at their level and one either
# side. The framework text is the stable prefix — the same for everyone at a
# role and level, so it caches — and the item is the volatile tail: the
# feedback, who gave it, where it already sits and the cells nobody wants.
class Evidence::PlacementPrompt
  # Recorded on every row, so the eval and the hub can tell prompts apart.
  # Bump it whenever the instructions, the framework text or the schema change.
  VERSION = "2026-10-20.1"
  ILLUSTRATIONS_PER_CELL = 3
  LEVEL_WINDOW = 1

  RELATIONSHIPS = {
    "manager_to_report" => "their manager",
    "report_to_manager" => "someone who reports to them",
    "peer_to_peer" => "a peer"
  }.freeze

  INSTRUCTIONS = <<~TEXT
    You help people place a piece of workplace feedback on their career framework. A framework lists capabilities, and for each capability a behavioural expectation per level. Placing feedback means linking it to the capability and level whose expectation it speaks to, with a valence: what the feedback says about that behaviour.

    Valences:
    - strongly_demonstrated: the feedback shows the behaviour clearly and well beyond doubt.
    - demonstrated: the feedback shows the behaviour.
    - growth_area: the feedback shows the behaviour is missing or inconsistent.
    - significant_growth_area: the feedback shows a serious or repeated gap.

    Suggest up to three placements, best first. Only suggest a cell when the feedback itself is evidence about that expectation; one well-supported placement beats three weak ones, and an empty list is the right answer when the feedback says nothing the framework covers. Prefer the person's own level unless the feedback clearly describes behaviour expected at the level above or below.

    For each placement give a confidence from 0 to 1 that the person deciding would place it there, and a one-sentence rationale that quotes the words in the feedback it rests on. Use only the capability ids and level numbers listed in the framework below, and never one of the cells the request says to leave out.
  TEXT

  attr_reader :item, :assignment

  # @param item [EvidenceItem]
  def initialize(item)
    @item = item
    @assignment = PersonFrameworkAssignment.find_by(person_id: item.person_id, framework_id: item.framework_id)
  end

  # @return [Boolean] whether there is anything to ask: an assignment with a
  #   level, and at least one cell still open
  def available?
    assignment.present? && home_level.present? && open_cells.any?
  end

  # @return [Hash{String => Hash}] "stableId|ordinal" => cell, for every cell
  #   in the level window the role reads
  def cells
    @cells ||= expectation_map.each_with_object({}) do |(token, info), acc|
      stable_id, ordinal = token.split("|")
      ordinal = ordinal.to_i
      next unless window.include?(ordinal)

      capability = capabilities[stable_id]
      next unless capability

      acc[token] = {
        capability_stable_id: stable_id, level_ordinal: ordinal,
        capability_name: info[:capability_name], capability_description: capability.description,
        category_name: capability.category&.name, expectation: info[:expectation],
        illustrations: Array(info[:illustrations]).first(ILLUSTRATIONS_PER_CELL)
      }
    end
  end

  # @return [Hash{String => Hash}] the cells the model may still suggest:
  #   not already linked, never dismissed for this item
  def open_cells
    @open_cells ||= cells.except(*(linked_tokens + dismissed_tokens))
  end

  # @param capability_stable_id [String]
  # @param level_ordinal [Integer]
  # @return [Boolean]
  def open_cell?(capability_stable_id, level_ordinal)
    open_cells.key?("#{capability_stable_id}|#{level_ordinal}")
  end

  # The stable prefix: instructions and the framework as this role reads it.
  #
  # @return [String]
  def framework_text
    lines = [ INSTRUCTIONS, "Framework: the #{role&.name} role, levels #{window.to_a.join(', ')} " \
                            "(this person is at level #{home_level.ordinal})." ]
    cells.values.group_by { |c| c[:capability_stable_id] }.each_value do |capability_cells|
      first = capability_cells.first
      lines << ""
      lines << "Capability #{first[:capability_stable_id]}: #{first[:capability_name]}" \
               "#{" (#{first[:category_name]})" if first[:category_name]}"
      lines << first[:capability_description] if first[:capability_description].present?
      capability_cells.sort_by { |c| c[:level_ordinal] }.each do |cell|
        lines << "  Level #{cell[:level_ordinal]}: #{cell[:expectation]}"
        cell[:illustrations].each { |example| lines << "    Example: #{example}" }
      end
    end
    lines.join("\n")
  end

  # The volatile tail: the feedback and what is already decided about it.
  #
  # @return [String]
  def item_text
    lines = [ "Feedback from #{relationship}, recorded as #{item_type}:", "", item.content.to_s.strip ]
    lines += [ "", "Already placed at (do not suggest these): #{cell_list(linked_tokens)}" ] if linked_tokens.any?
    lines += [ "", "Someone already rejected these (do not suggest them): #{cell_list(dismissed_tokens)}" ] if dismissed_tokens.any?
    lines.join("\n")
  end

  # Enums of every candidate value, so the model cannot invent an id. The
  # pair is re-checked against {#open_cell?} afterwards: an enum per field
  # cannot say which combinations exist.
  #
  # @return [Hash] a JSON schema for `output_config.format`
  def schema
    {
      type: "object", additionalProperties: false, required: [ "suggestions" ],
      properties: {
        suggestions: {
          type: "array",
          items: {
            type: "object", additionalProperties: false,
            required: %w[capability_stable_id level_ordinal valence confidence rationale],
            properties: {
              capability_stable_id: { type: "string", enum: cells.values.map { |c| c[:capability_stable_id] }.uniq.sort },
              level_ordinal: { type: "integer", enum: cells.values.map { |c| c[:level_ordinal] }.uniq.sort },
              valence: { type: "string", enum: EvidenceLink::VALENCES },
              confidence: { type: "number" },
              rationale: { type: "string" }
            }
          }
        }
      }
    }
  end

  private

  def expectation_map
    Evidence::FrameworkCellOptions.new(framework_id: assignment.framework_id, role_id: assignment.role_id).expectation_map
  end

  def role
    @role ||= FrameworkState::Role.find_by(role_id: assignment.role_id)
  end

  def home_level
    return @home_level if defined?(@home_level)

    @home_level = assignment && FrameworkState::Level.find_by(level_id: assignment.level_id)
  end

  def window
    (home_level.ordinal - LEVEL_WINDOW)..(home_level.ordinal + LEVEL_WINDOW)
  end

  # stable_id => active capability in this framework
  def capabilities
    @capabilities ||= FrameworkState::Capability.active
      .joins(:category).merge(FrameworkState::CapabilityCategory.where(framework_id: assignment.framework_id))
      .includes(:category).index_by(&:stable_id)
  end

  def linked_tokens
    @linked_tokens ||= EvidenceLink.active.where(evidence_id: item.id)
      .pluck(:capability_stable_id, :level_ordinal).map { |cap, level| "#{cap}|#{level}" }
  end

  def dismissed_tokens
    @dismissed_tokens ||= EvidencePlacementSuggestion.for_evidence(item.id).where(status: "dismissed")
      .pluck(:capability_stable_id, :level_ordinal).map { |cap, level| "#{cap}|#{level}" }
  end

  def cell_list(tokens)
    tokens.map do |token|
      cap, level = token.split("|")
      name = cells.dig(token, :capability_name) || capabilities[cap]&.name
      "#{name} (#{cap}) level #{level}"
    end.join("; ")
  end

  def relationship
    RELATIONSHIPS.fetch(item.feedback_direction.to_s) do
      item.source == "manager" ? "their manager" : "a colleague"
    end
  end

  def item_type
    item.evidence_type == "other" ? item.custom_type_label.to_s : item.evidence_type.humanize.downcase
  end
end
