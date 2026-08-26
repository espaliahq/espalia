# frozen_string_literal: true

# Builds the surgical Turbo Stream response for an inline suggestion
# resolution (approve / reject) so the acting user's grid updates in place.
#
# Before this, every inline resolution answered 204 and the client re-fetched
# the ENTIRE matrix frame — several MB of edit-mode HTML with thousands of
# Stimulus controller mounts on a real framework, which froze the tab for
# seconds per approval (field report: the browser's "wait or quit" dialog).
# The affected entity already lives inside an addressable Turbo Frame, so the
# resolution response replaces just that frame instead.
#
# Coverage is deliberately partial: the shape-preserving content kinds a
# reviewer actions in bulk (illustration / expectation / capability / category
# edits, illustration creates). Anything else — shape-changing creates and
# archives (which also flip the draft pill / row strikethrough outside any
# frame), org-structure suggestions — returns nil, the controller answers 204,
# and the client falls back to the full matrix refresh exactly as before.
#
# Every builder re-queries the entity's pending state and re-threads
# mode/authority into the frame it renders (Hard-Won Lessons 13/16), mirroring
# the per-entity inline-edit controllers.
module Frameworks::SuggestionResolutionStreams
  # @param outcome [Symbol] :approved or :rejected
  # @return [Array, nil] turbo_stream fragments, or nil when the suggestion's
  #   shape has no surgical rendering (caller falls back to 204 + full refresh)
  def resolution_streams(outcome:)
    case [ @suggestion.kind, @suggestion.target_entity_type ]
    when [ "edit", "role_illustration" ]        then illustration_edit_stream
    when [ "edit", "behavioural_expectation" ]  then expectation_edit_stream
    when [ "edit", "capability" ]               then capability_edit_stream
    when [ "edit", "capability_category" ]      then category_edit_stream
    when [ "create", "role_illustration" ]      then illustration_create_streams(outcome)
    end
  rescue StandardError => e
    # The resolution itself already succeeded — a failed surgical render must
    # degrade to the 204 + full-refresh fallback, never surface as an error.
    Rails.logger.warn("Suggestion resolution stream failed (#{@suggestion.suggestion_id}): #{e.message}")
    nil
  end

  private

  # Re-render the illustration's frame — approve shows the applied text,
  # reject drops the inline diff; both re-query what's still pending.
  def illustration_edit_stream
    illustration = FrameworkState::RoleIllustration.find_by(
      illustration_id: @suggestion.target_entity_id
    )
    return nil unless illustration

    pending_edit = latest_pending_descriptor("role_illustration", illustration.illustration_id, "description")
    [ turbo_stream.replace(
      "illustration-#{illustration.illustration_id}",
      render_to_string(
        Views::Frameworks::Explorer::IllustrationFrame.new(
          illustration: illustration,
          framework_id: @framework.framework_id,
          mode: :edit,
          pending_edit_count: pending_proposal_count("role_illustration", illustration.illustration_id),
          pending_edit: pending_edit,
          can_reorder: policy(@framework).reorder_illustrations?,
          approval_authority: pending_edit ? framework_suggestion_approval_authority : Frameworks::SuggestionApprovalAuthority.none
        ),
        layout: false
      )
    ) ]
  end

  def expectation_edit_stream
    expectation = graph_entity(:expectations, @suggestion.target_entity_id)
    return nil unless expectation

    [ turbo_stream.replace(
      "expectation-text-#{expectation.expectation_id}",
      render_to_string(
        Views::Frameworks::Explorer::ExpectationTextFrame.new(
          expectation: expectation,
          framework_id: @framework.framework_id,
          mode: :edit,
          pending_edit_count: pending_proposal_count("behavioural_expectation", expectation.expectation_id),
          pending_edit: latest_pending_descriptor("behavioural_expectation", expectation.expectation_id, "description")
        ),
        layout: false
      )
    ) ]
  end

  def capability_edit_stream
    capability = graph_entity(:capabilities, @suggestion.target_entity_id)
    return nil unless capability

    field = @suggestion.field
    frame_class, frame_id =
      case field
      when "name" then [ Views::Frameworks::Explorer::CapabilityNameFrame, "capability-name" ]
      when "description" then [ Views::Frameworks::Explorer::CapabilityDescriptionFrame, "capability-description" ]
      end
    return nil unless frame_class

    [ turbo_stream.replace(
      "#{frame_id}-#{capability.capability_id}",
      render_to_string(
        frame_class.new(
          capability: capability,
          framework_id: @framework.framework_id,
          mode: :edit,
          pending_edit_count: pending_field_edit_count("capability", capability.capability_id, field),
          pending_edit: latest_pending_descriptor("capability", capability.capability_id, field)
        ),
        layout: false
      )
    ) ]
  end

  def category_edit_stream
    category = FrameworkState::CapabilityCategory.find_by(
      framework_id: @framework.framework_id,
      category_id: @suggestion.target_entity_id,
      status: "active"
    )
    return nil unless category

    field = @suggestion.field
    frame_class, frame_id =
      case field
      when "name" then [ Views::Frameworks::Explorer::CategoryNameFrame, "category-name" ]
      when "description" then [ Views::Frameworks::Explorer::CategoryDescriptionFrame, "category-description" ]
      end
    return nil unless frame_class

    [ turbo_stream.replace(
      "#{frame_id}-#{category.category_id}",
      render_to_string(
        frame_class.new(
          category: category,
          framework_id: @framework.framework_id,
          mode: :edit,
          pending_edit_count: pending_field_edit_count("capability_category", category.category_id, field),
          pending_edit: latest_pending_descriptor("capability_category", category.category_id, field)
        ),
        layout: false
      )
    ) ]
  end

  # Approving a new-illustration proposal replaces its ghost with the real
  # (just-projected) illustration; rejecting removes the ghost.
  def illustration_create_streams(outcome)
    return [ turbo_stream.remove("pending-suggestion-#{@suggestion.suggestion_id}") ] unless outcome == :approved

    illustration = created_illustration_for_suggestion
    return nil unless illustration

    [ turbo_stream.replace(
      "pending-suggestion-#{@suggestion.suggestion_id}",
      render_to_string(
        Views::Frameworks::Explorer::IllustrationFrame.new(
          illustration: illustration,
          framework_id: @framework.framework_id,
          mode: :edit,
          can_reorder: policy(@framework).reorder_illustrations?
        ),
        layout: false
      )
    ) ]
  end

  # The applied illustration row — the projection runs synchronously inside
  # the approve, so it exists by response time. The creating event's id never
  # reaches this layer, so resolve it by content: the proposal's final text
  # (an amend folds into suggested_value) within the target expectation × role,
  # newest first in case of duplicates. No text match = we can't prove which
  # row the projection created — return nil (→ 204 + full refresh) rather
  # than render a sibling row into the ghost's place, which would duplicate it.
  def created_illustration_for_suggestion
    attrs = (@suggestion.proposed_attributes || {}).stringify_keys
    scope = FrameworkState::RoleIllustration.where(
      expectation_id: @suggestion.parent_id, role_id: attrs["role_id"]
    ).order(created_at: :desc)
    final_text = @suggestion.suggested_value.presence || attrs["description"]
    scope.find_by(description: final_text)
  end

  # ── Pending-state re-queries (Hard-Won Lesson 16) ──

  def pending_scope_for(entity_type, entity_id)
    FrameworkState::SuggestedEdit.where(
      framework_id: @framework.framework_id,
      target_entity_type: entity_type,
      target_entity_id: entity_id,
      status: "pending"
    )
  end

  # Illustrations/expectations count all pending proposals (single text field);
  # capabilities/categories count per field — mirrors the per-entity
  # inline-edit controllers so the wiggle count can't diverge between paths.
  def pending_proposal_count(entity_type, entity_id)
    pending_scope_for(entity_type, entity_id).proposals.count
  end

  def pending_field_edit_count(entity_type, entity_id, field)
    pending_scope_for(entity_type, entity_id).edits.where(field: field).count
  end

  def latest_pending_descriptor(entity_type, entity_id, field)
    edit = pending_scope_for(entity_type, entity_id)
      .edits.where(field: field).order(created_at: :desc).first
    return nil unless edit

    { suggested_value: edit.suggested_value,
      suggestion_id: edit.suggestion_id,
      created_at: edit.created_at }
  end

  # ── Graph lookups (Hard-Won Lesson 17: draft-added entities aren't in the
  # read model; an approved edit rewrote the snapshot, so load fresh) ──

  def graph_entity(kind, entity_id)
    graph = Frameworks::ExplorerGraph.load(@framework.framework_id) ||
            Frameworks::ExplorerGraph.rebuild(@framework.framework_id)
    capabilities = graph.capability_categories.flat_map(&:capabilities)
    case kind
    when :capabilities
      capabilities.find { |c| c.capability_id == entity_id }
    when :expectations
      capabilities.flat_map(&:expectations).find { |e| e.expectation_id == entity_id }
    end
  end
end
