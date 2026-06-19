# frozen_string_literal: true

# Authors a behavioural expectation in a previously-empty capability × level
# cell — the canonical statement people are rated against at that level. This
# fills a gap in the rating grid; editing the *text* of an existing expectation
# is a separate (suggest-based) path.
#
# Shape-changing — it adds a cell to the (capability_stable_id, level_ordinal)
# grid, so it auto-opens a draft (see Frameworks::Aggregate#set_behavioural_expectation)
# and is deferred from the published read model until publish.
#
# Write — :mcp_client. Restricted to edit-rights holders
# (FrameworkPolicy#add_expectation?).
class Operations::Frameworks::SetBehaviouralExpectation < Operations::Base
  description "Author a behavioural expectation for an empty capability × level cell (owner/editor/lead only)."
  category :write
  approval :mcp_client

  parameter :framework_id,  String,  required: true
  parameter :capability_id, String,  required: true
  parameter :level_ordinal, Integer, required: true
  parameter :description,   String,  required: true

  def policy_check
    authorize framework, :add_expectation?
  end

  # @return [Hash] { framework_id:, capability_id:, expectation_id:, stable_id:, level_ordinal: }
  def perform
    validate_description!
    ensure_cell_empty!

    expectation_id = SecureRandom.uuid_v7
    stable_id = SecureRandom.uuid_v7
    Frameworks::CommandHandler.new.set_behavioural_expectation(
      framework.framework_id, expectation_id, stable_id,
      capability.capability_id, params[:level_ordinal], params[:description]
    )

    {
      framework_id: framework.framework_id,
      capability_id: capability.capability_id,
      expectation_id: expectation_id,
      stable_id: stable_id,
      level_ordinal: params[:level_ordinal]
    }
  end

  private

  def validate_description!
    return if params[:description].strip.present?

    raise Operations::Base::ParameterError, "description can't be blank"
  end

  # The aggregate keys uniqueness on a fresh expectation_id, so it wouldn't stop
  # a second expectation on the same cell — guard here against authoring a
  # duplicate over an existing (capability × ordinal) expectation. Checks the
  # graph so an expectation added earlier in the current draft is also caught.
  def ensure_cell_empty!
    return unless capability.expectations.any? { |e| e.level_ordinal == params[:level_ordinal] }

    raise Operations::Base::ParameterError,
          "capability #{capability.capability_id} already has an expectation at level #{params[:level_ordinal]}"
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
