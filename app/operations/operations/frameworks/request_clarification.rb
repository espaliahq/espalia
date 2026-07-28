# frozen_string_literal: true

# Requests clarification of a capability × level cell — a NON-PROPOSAL
# suggestion that anchors a lifecycled discussion ("what does this expectation
# actually mean?") without proposing a value. It may resolve into a rewording,
# better illustrations, or "the text is fine, here's the reading" — the
# resolution verb is resolve-with-note (frameworks_resolve_clarification),
# never approve/reject.
#
# Anchoring: the cell's behavioural expectation when one exists (it IS the
# capability × level); otherwise the capability, carrying the level_ordinal —
# "nothing defined here" being a legitimate complaint.
#
# Write — :mcp_client, on the suggest bar like every other suggestion create.
class Operations::Frameworks::RequestClarification < Operations::Base
  description "Ask for clarification of a capability × level expectation — opens a discussion, proposes nothing."
  category :write
  approval :mcp_client

  parameter :framework_id,  String,  required: true
  parameter :capability_id, String,  required: true
  parameter :level_ordinal, Integer, required: true
  # rationale is the question itself — what is unclear about this cell.
  parameter :rationale,     String,  required: true

  def policy_check
    authorize FrameworkState::SuggestedEdit.new(framework_id: framework.framework_id), :create?
  end

  # @return [Hash] { framework_id:, suggestion_id:, capability_id:, level_ordinal:, target_entity_type: }
  def perform
    validate_rationale!
    require_author!

    suggestion_id = SecureRandom.uuid_v7
    Frameworks::CommandHandler.new.request_clarification(
      framework.framework_id, suggestion_id, anchor_type, anchor_id,
      author_id: author_id, level_ordinal: params[:level_ordinal], rationale: params[:rationale]
    )

    {
      framework_id: framework.framework_id,
      suggestion_id: suggestion_id,
      capability_id: capability.capability_id,
      level_ordinal: params[:level_ordinal],
      target_entity_type: anchor_type
    }
  end

  private

  def anchor_type
    expectation ? "behavioural_expectation" : "capability"
  end

  def anchor_id
    expectation ? expectation.expectation_id : capability.capability_id
  end

  # The cell's expectation, if one exists — resolved from the explorer graph so
  # a draft-authored expectation anchors correctly too (Lesson 17).
  def expectation
    return @expectation if defined?(@expectation)

    @expectation = capability.expectations.find { |e| e.level_ordinal == params[:level_ordinal] }
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
  # scopes the lookup to the authorized framework.
  def capability
    @capability ||= explorer_graph.capability_categories.flat_map(&:capabilities)
      .find { |c| c.capability_id == params[:capability_id] } ||
      raise(ActiveRecord::RecordNotFound, "capability #{params[:capability_id]} not found in this framework")
  end

  def explorer_graph
    @explorer_graph ||= Frameworks::ExplorerGraph.load(framework.framework_id) ||
                        Frameworks::ExplorerGraph.rebuild(framework.framework_id)
  end
end
