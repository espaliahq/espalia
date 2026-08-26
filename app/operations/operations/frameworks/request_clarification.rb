# frozen_string_literal: true

# Requests clarification of a framework entity — a NON-PROPOSAL suggestion that
# anchors a lifecycled discussion ("what does this expectation actually mean?")
# without proposing a value. It may resolve into a rewording, better
# illustrations, or "the text is fine, here's the reading" — the resolution verb
# is resolve-with-note (frameworks_resolve_clarification), never approve/reject.
#
# Anchoring, most specific first:
# - `illustration_id` given → the role illustration (one example under a cell);
#   the level comes from its owning expectation.
# - otherwise the cell's behavioural expectation when one exists (it IS the
#   capability × level).
# - otherwise the capability, carrying `level_ordinal` when given — "nothing
#   defined here" being a legitimate complaint. With no ordinal the question is
#   about the capability as a whole.
#
# Write — :mcp_client, on the suggest bar like every other suggestion create.
class Operations::Frameworks::RequestClarification < Operations::Base
  description "Ask for clarification of a capability, one of its level expectations, or a role " \
              "illustration — opens a discussion, proposes nothing."
  category :write
  approval :mcp_client

  parameter :framework_id,    String,  required: true
  # Either capability_id or illustration_id identifies the anchor — exactly one
  # is required, which JSON Schema `required` can't express for a choice, so the
  # obligation is stated in each param's description (and enforced in #perform).
  # When both are given the illustration wins (it is the more specific target).
  parameter :capability_id,   String,  required: false, schema: {
    type: "string",
    description: "The capability to anchor on. Required unless illustration_id is given."
  }
  parameter :illustration_id, String,  required: false, schema: {
    type: "string",
    description: "A role illustration to anchor on — the most specific target, and its " \
                 "level is taken from the owning expectation. Required unless capability_id is given."
  }
  # Optional for a capability-wide question; ignored for an illustration anchor
  # (the owning expectation's level is authoritative).
  parameter :level_ordinal,   Integer, required: false
  # rationale is the question itself — what is unclear about this entity.
  parameter :rationale,       String,  required: true

  def policy_check
    authorize FrameworkState::SuggestedEdit.new(framework_id: framework.framework_id), :create?
  end

  # @return [Hash] { framework_id:, suggestion_id:, capability_id:, illustration_id:,
  #   level_ordinal:, target_entity_type: }
  def perform
    validate_target!
    validate_rationale!
    require_author!

    suggestion_id = SecureRandom.uuid_v7
    Frameworks::CommandHandler.new.request_clarification(
      framework.framework_id, suggestion_id, anchor_type, anchor_id,
      author_id: author_id, level_ordinal: level_ordinal, rationale: params[:rationale]
    )

    {
      framework_id: framework.framework_id,
      suggestion_id: suggestion_id,
      capability_id: capability.capability_id,
      illustration_id: illustration&.illustration_id,
      level_ordinal: level_ordinal,
      target_entity_type: anchor_type
    }
  end

  private

  def anchor_type
    return "role_illustration" if illustration
    return "behavioural_expectation" if expectation

    "capability"
  end

  def anchor_id
    return illustration.illustration_id if illustration
    return expectation.expectation_id if expectation

    capability.capability_id
  end

  # An illustration anchor takes its level from the expectation that owns it —
  # any client-supplied ordinal would be redundant at best, wrong at worst.
  def level_ordinal
    illustration ? expectation.level_ordinal : params[:level_ordinal]
  end

  # The anchored expectation: the illustration's owner when one was named, else
  # the cell's expectation if it exists. Resolved from the explorer graph so a
  # draft-authored expectation anchors correctly too (Lesson 17).
  def expectation
    return @expectation if defined?(@expectation)

    @expectation =
      if params[:illustration_id].present?
        graph_expectations.find { |e| e.expectation_id == illustration.expectation_id }
      else
        capability.expectations.find { |e| e.level_ordinal == params[:level_ordinal] }
      end
  end

  # Resolved from the explorer graph, which scopes the lookup to the authorized
  # framework (an illustration under another framework is simply not found).
  def illustration
    return @illustration if defined?(@illustration)
    return @illustration = nil if params[:illustration_id].blank?

    @illustration = graph_expectations.flat_map(&:illustrations)
      .find { |i| i.illustration_id == params[:illustration_id] } ||
      raise(ActiveRecord::RecordNotFound,
            "illustration #{params[:illustration_id]} not found in this framework")
  end

  def graph_expectations
    @graph_expectations ||= graph_capabilities.flat_map(&:expectations)
  end

  def validate_target!
    return if params[:capability_id].present? || params[:illustration_id].present?

    raise Operations::Base::ParameterError, "capability_id or illustration_id is required"
  end

  def author_id
    context.person&.id&.to_s
  end

  def require_author!
    return if author_id.present?

    raise Operations::Base::ParameterError,
          "Requesting a clarification requires a linked person; this account has none."
  end

  def validate_rationale!
    return if params[:rationale].strip.present?

    raise Operations::Base::ParameterError, "rationale can't be blank"
  end

  def framework
    @framework ||= FrameworkState::Framework.find_by!(framework_id: params[:framework_id])
  end

  # Resolve from the explorer graph (incl. draft-added capabilities), which also
  # scopes the lookup to the authorized framework. An illustration anchor
  # identifies its capability through the expectation that owns it, so
  # capability_id is optional in that mode.
  def capability
    @capability ||= graph_capabilities.find { |c| c.capability_id == target_capability_id } ||
      raise(ActiveRecord::RecordNotFound, "capability #{target_capability_id} not found in this framework")
  end

  def target_capability_id
    params[:illustration_id].present? ? expectation.capability_id : params[:capability_id]
  end

  def graph_capabilities
    @graph_capabilities ||= explorer_graph.capability_categories.flat_map(&:capabilities)
  end

  def explorer_graph
    @explorer_graph ||= Frameworks::ExplorerGraph.load(framework.framework_id) ||
                        Frameworks::ExplorerGraph.rebuild(framework.framework_id)
  end
end
