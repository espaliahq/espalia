# frozen_string_literal: true

# Converts a loaded {Frameworks::Aggregate} into a
# {Frameworks::ExplorerGraph::Framework} value tree.
#
# Runs on an already-loaded aggregate — no additional event-stream reads. The
# builder walks the aggregate's flat ivar hashes and produces nested value
# objects duck-typing the surface {Frameworks::MatrixDataBuilder} expects
# from {FrameworkState::*} AR records.
#
# Draft-state tagging: for entities added in the currently-open draft,
# sets `added_in_draft: true`. For a capability archived inside an open
# draft but not yet published, sets `pending_archive: true` and keeps
# `status: "active"` so view-mode consumers see the published-like state.
#
class Frameworks::ExplorerGraphBuilder
  # @param aggregate [Frameworks::Aggregate] loaded via Repository#with_framework
  def initialize(aggregate)
    @aggregate = aggregate
  end

  # @return [Frameworks::ExplorerGraph::Framework]
  def build
    Frameworks::ExplorerGraph::Framework.new(
      framework_id: @aggregate.framework_id,
      name: @aggregate.name,
      current_published_version: @aggregate.current_version,
      draft_in_progress: @aggregate.draft_in_progress,
      draft_version: @aggregate.draft_version,
      role_families: build_role_families,
      capability_categories: build_capability_categories
    )
  end

  private

  def build_role_families
    @aggregate.role_families.map do |rfid, data|
      Frameworks::ExplorerGraph::RoleFamily.new(
        role_family_id: rfid,
        name: data[:name],
        description: data[:description],
        # `department` is event-sourced on RoleFamilyAdded/Updated. Transitional
        # fallback to the AR read model for families whose streams predate the
        # backfill (events:backfill_role_family_departments) — remove the
        # fallback (and `department_by_role_family`) once it has run everywhere.
        department: data[:department].presence || department_by_role_family[rfid],
        roles: build_roles_for(rfid)
      )
    end
  end

  def department_by_role_family
    @department_by_role_family ||=
      if @aggregate.framework_id
        FrameworkState::RoleFamily
          .where(framework_id: @aggregate.framework_id)
          .pluck(:role_family_id, :department)
          .to_h
      else
        {}
      end
  end

  def build_roles_for(role_family_id)
    @aggregate.roles
      .select { |_rid, data| data[:role_family_id] == role_family_id }
      .map do |rid, data|
        Frameworks::ExplorerGraph::Role.new(
          role_id: rid,
          role_family_id: role_family_id,
          name: data[:name],
          code: data[:code],
          track: data[:track],
          levels: build_levels_for(rid)
        )
      end
  end

  def build_levels_for(role_id)
    @aggregate.levels
      .select { |_lid, data| data[:role_id] == role_id }
      .sort_by { |_lid, data| data[:ordinal] }
      .map do |lid, data|
        Frameworks::ExplorerGraph::Level.new(
          level_id: lid,
          role_id: role_id,
          ordinal: data[:ordinal],
          title: data[:title],
          code: data[:code],
          is_entry: data[:is_entry] || false,
          added_in_draft: @aggregate.draft_added_level_ids.include?(lid)
        )
      end
  end

  def build_capability_categories
    @aggregate.capability_categories
      .sort_by { |_cid, data| data[:ordinal] || 0 }
      .map do |cat_id, data|
        Frameworks::ExplorerGraph::CapabilityCategory.new(
          category_id: cat_id,
          name: data[:name],
          description: data[:description],
          ordinal: data[:ordinal],
          deficit_threshold: data[:deficit_threshold],
          overperformance_cap: data[:overperformance_cap],
          status: (data[:status] || :active).to_s,
          capabilities: build_capabilities_for(cat_id)
        )
      end
  end

  def build_capabilities_for(category_id)
    @aggregate.capabilities
      .select { |_cid, data| data[:category_id] == category_id }
      .map do |cap_id, data|
        status = data[:status]
        pending_archive = pending_archive?(data)
        # Keep the published-world status for view-mode consumers — a
        # capability archived inside an open draft is still "active" from
        # the published view's perspective until publish rebuilds.
        effective_status = pending_archive ? :active : status

        Frameworks::ExplorerGraph::Capability.new(
          capability_id: cap_id,
          stable_id: data[:stable_id],
          category_id: category_id,
          name: data[:name],
          description: data[:description],
          status: effective_status.to_s,
          bindings: build_bindings_for(cap_id),
          expectations: build_expectations_for(cap_id),
          added_in_draft: @aggregate.draft_added_capability_ids.include?(cap_id),
          pending_archive: pending_archive
        )
      end
  end

  def pending_archive?(capability_data)
    return false unless @aggregate.draft_in_progress
    return false unless capability_data[:status] == :archived

    # Archived inside the current draft is only "pending" if the capability
    # pre-existed the draft — otherwise it's just a create-then-archive and
    # isn't visible in the published view at all.
    !@aggregate.added_during_draft.include?(capability_data[:stable_id])
  end

  def build_bindings_for(capability_id)
    @aggregate.bindings
      .select { |_bid, data| data[:capability_id] == capability_id }
      .map do |bid, data|
        Frameworks::ExplorerGraph::CapabilityRoleBinding.new(
          binding_id: bid,
          capability_id: capability_id,
          role_id: data[:role_id],
          weight: data[:weight],
          individual_tolerance: data[:individual_tolerance],
          added_in_draft: @aggregate.draft_added_binding_ids.include?(bid)
        )
      end
  end

  def build_expectations_for(capability_id)
    @aggregate.expectations
      .select { |_eid, data| data[:capability_id] == capability_id }
      .sort_by { |_eid, data| data[:level_ordinal] }
      .map do |exp_id, data|
        Frameworks::ExplorerGraph::BehaviouralExpectation.new(
          expectation_id: exp_id,
          stable_id: data[:stable_id],
          capability_id: capability_id,
          level_ordinal: data[:level_ordinal],
          description: data[:description],
          illustrations: build_illustrations_for(exp_id),
          added_in_draft: @aggregate.draft_added_expectation_ids.include?(exp_id)
        )
      end
  end

  def build_illustrations_for(expectation_id)
    @aggregate.illustrations
      .select { |_iid, data| data[:expectation_id] == expectation_id }
      .sort_by { |_iid, data| data[:ordinal] || 0 }
      .map do |ill_id, data|
        Frameworks::ExplorerGraph::RoleIllustration.new(
          illustration_id: ill_id,
          stable_id: data[:stable_id],
          expectation_id: expectation_id,
          role_id: data[:role_id],
          ordinal: data[:ordinal],
          description: data[:description]
        )
      end
  end
end
