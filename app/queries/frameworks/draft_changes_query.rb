# frozen_string_literal: true

# What publishing the open draft changes in the rating grid, so the person
# confirming it can see what they are about to make live (#497).
#
# A diff of the edit-mode graph against the published read model, not a walk
# of the events: a binding removed and then re-added in the same draft changes
# nothing, and must not be listed.
#
# Lists only shape-changing changes — the ones held back until publish.
# Renames, rewordings and examples apply live, so they are already published.
class Frameworks::DraftChangesQuery
  # The order the review page lists the kinds in.
  KINDS = %i[
    capabilities_added capabilities_archived categories_archived
    roles_removed roles_added levels_added expectations_added
  ].freeze

  # @param framework [FrameworkState::Framework]
  def initialize(framework)
    @framework = framework
  end

  # @return [Hash{Symbol => Array<Hash>}] each of {KINDS}, possibly empty
  def call
    @call ||= {
      capabilities_added: capabilities_added,
      capabilities_archived: capabilities_archived,
      categories_archived: categories_archived,
      roles_removed: roles_removed,
      roles_added: roles_added,
      levels_added: levels_added,
      expectations_added: expectations_added
    }
  end

  # @return [Boolean]
  def empty? = call.values.all?(&:empty?)

  private

  def capabilities_added
    capabilities.select { |c| c.added_in_draft && !c.pending_archive }.map do |c|
      { capability: c.name, category: category_names[c.category_id],
        roles: c.bindings.map { |b| role_name(b.role_id) }.sort }
    end
  end

  def capabilities_archived
    capabilities.select { |c| c.pending_archive && !c.added_in_draft }
      .map { |c| { capability: c.name, open_cycle_people: open_cycle_people(c.bindings.map(&:role_id)) } }
  end

  def categories_archived
    published_active = FrameworkState::CapabilityCategory
      .where(framework_id: @framework.framework_id, status: "active").pluck(:category_id).to_set
    graph.capability_categories
      .select { |cat| cat.status == "archived" && published_active.include?(cat.category_id) }
      .map { |cat| { category: cat.name } }
  end

  # Compared by (capability, role), not binding id: removing a binding and
  # adding it back mints a new id for what is, to an assessment, no change.
  # A capability being archived loses every role with it; that is listed once,
  # as the archive, rather than once per role.
  def roles_removed
    archiving = capabilities.select(&:pending_archive).map(&:capability_id).to_set

    published_bindings
      .reject { |b| draft_pairs.include?([ b.capability_id, b.role_id ]) || archiving.include?(b.capability_id) }
      .map do |b|
        { capability: capability_name(b.capability_id), role: role_name(b.role_id),
          open_cycle_people: open_cycle_people([ b.role_id ]) }
      end
  end

  # A new capability's roles are part of adding it.
  def roles_added
    capabilities.reject(&:added_in_draft).flat_map do |c|
      c.bindings
        .reject { |b| published_pairs.include?([ c.capability_id, b.role_id ]) }
        .map { |b| { capability: c.name, role: role_name(b.role_id) } }
    end
  end

  def levels_added
    roles.flat_map do |role|
      role.levels.select(&:added_in_draft).map do |level|
        { role: "#{role.code} · #{role.name}", level: level.code.presence || "L#{level.ordinal}", title: level.title }
      end
    end
  end

  def expectations_added
    capabilities.reject(&:added_in_draft).flat_map do |c|
      c.expectations.select(&:added_in_draft).map { |e| { capability: c.name, level_ordinal: e.level_ordinal } }
    end
  end

  # People in an open cycle of this framework, enrolled at one of `role_ids` —
  # the assessments a change reaches the moment it publishes.
  def open_cycle_people(role_ids)
    return 0 if role_ids.empty?

    AssessmentCycleEnrollment.active
      .where(cycle_id: open_cycle_ids, role_id: role_ids)
      .distinct.count(:person_id)
  end

  def open_cycle_ids
    @open_cycle_ids ||= AssessmentCycle.open_cycles.for_framework(@framework.framework_id).pluck(:cycle_id)
  end

  def published_bindings
    @published_bindings ||= FrameworkState::CapabilityRoleBinding
      .where(capability_id: published_capability_ids)
      .to_a
  end

  def published_pairs
    @published_pairs ||= published_bindings.to_set { |b| [ b.capability_id, b.role_id ] }
  end

  def draft_pairs
    @draft_pairs ||= capabilities.flat_map { |c| c.bindings.map { |b| [ c.capability_id, b.role_id ] } }.to_set
  end

  def published_capability_ids
    FrameworkState::Capability
      .joins(:category).where(framework_capability_categories: { framework_id: @framework.framework_id })
      .pluck(:capability_id)
  end

  def capability_name(capability_id)
    @capability_names ||= capabilities.to_h { |c| [ c.capability_id, c.name ] }
    @capability_names[capability_id]
  end

  def role_name(role_id)
    @role_names ||= roles.to_h { |r| [ r.role_id, r.name ] }
    @role_names[role_id]
  end

  def category_names
    @category_names ||= graph.capability_categories.to_h { |cat| [ cat.category_id, cat.name ] }
  end

  def capabilities
    @capabilities ||= graph.capability_categories.flat_map(&:capabilities)
  end

  def roles
    @roles ||= graph.role_families.flat_map(&:roles)
  end

  def graph
    @graph ||= Frameworks::ExplorerGraph.load(@framework.framework_id) ||
               Frameworks::ExplorerGraph.rebuild(@framework.framework_id)
  end
end
