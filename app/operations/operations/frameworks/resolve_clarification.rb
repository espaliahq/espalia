# frozen_string_literal: true

# Resolves a pending clarification with a note — the discussion's outcome
# ("reworded L4 — see suggestion …", "added two illustrations", "wording is
# fine; here's the reading"), optionally linking the concrete suggestion the
# discussion spawned.
#
# Authority mirrors expectation-tier approval (FrameworkSuggestionPolicy#resolve?):
# whoever could change the text can declare the question settled.
class Operations::Frameworks::ResolveClarification < Operations::Base
  description "Resolve a pending clarification with a note (expectation-tier authority required)."
  category :write
  approval :mcp_client
  prose_fields :note

  parameter :framework_id,  String, required: true
  parameter :suggestion_id, String, required: true
  # note = what settled the question; resulting_suggestion_id optionally links
  # the concrete change suggestion the discussion led to.
  parameter :note,          String, required: true
  parameter :resulting_suggestion_id, String

  def policy_check
    authorize suggestion, :resolve?
  end

  # @return [Hash] { framework_id:, suggestion_id:, status: }
  def perform
    validate_note!
    validate_resulting_suggestion!

    Frameworks::CommandHandler.new.resolve_clarification(
      framework.framework_id,
      suggestion.suggestion_id,
      context.person&.id&.to_s,
      note: params[:note],
      resulting_suggestion_id: params[:resulting_suggestion_id].presence
    )

    { framework_id: framework.framework_id, suggestion_id: suggestion.suggestion_id, status: suggestion.reload.status }
  end

  private

  def validate_note!
    return if params[:note].strip.present?

    raise Operations::Base::ParameterError, "note can't be blank"
  end

  # When a resulting suggestion is named, it must be a real suggestion on this
  # framework — a dangling link would render as a dead reference forever.
  def validate_resulting_suggestion!
    rsid = params[:resulting_suggestion_id].presence
    return if rsid.nil?
    return if framework.suggested_edits.exists?(suggestion_id: rsid)

    raise Operations::Base::ParameterError,
          "resulting_suggestion_id #{rsid} is not a suggestion on this framework"
  end

  def framework
    @framework ||= FrameworkState::Framework.find_by!(framework_id: params[:framework_id])
  end

  def suggestion
    @suggestion ||= framework.suggested_edits.find_by!(suggestion_id: params[:suggestion_id])
  end
end
