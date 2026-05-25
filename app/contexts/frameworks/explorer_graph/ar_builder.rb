# frozen_string_literal: true

# Fallback builder that constructs a {Frameworks::ExplorerGraph::Framework}
# directly from the `FrameworkState::*` AR tree.
#
# Used when no snapshot row exists for a framework (test factories that
# bypass the command path, pre-1b rows). Assumes the framework is in its
# published state — draft-only flags default to false because AR rows don't
# carry draft provenance.
#
# For any framework reached via {Frameworks::Repository#with_framework}, the
# snapshot is kept current and the aggregate-backed
# {Frameworks::ExplorerGraphBuilder} is the authoritative path.
#
class Frameworks::ExplorerGraph::ArBuilder
  # @param framework [FrameworkState::Framework]
  def initialize(framework)
    @framework = framework
  end

  # @return [Frameworks::ExplorerGraph::Framework]
  def build
    Frameworks::ExplorerGraph::Framework.new(
      framework_id: @framework.framework_id,
      name: @framework.name,
      current_published_version: @framework.current_published_version,
      draft_in_progress: @framework.draft_in_progress,
      draft_version: @framework.draft_version,
      role_families: build_role_families,
      capability_categories: build_capability_categories
    )
  end

  private

  def build_role_families
    @framework.role_families.includes(roles: :levels).order(:name).map do |rf|
      Frameworks::ExplorerGraph::RoleFamily.new(
        role_family_id: rf.role_family_id,
        name: rf.name,
        description: rf.description,
        department: rf.try(:department),
        roles: rf.roles.map { |r| build_role(r) }
      )
    end
  end

  def build_role(role)
    Frameworks::ExplorerGraph::Role.new(
      role_id: role.role_id,
      role_family_id: role.role_family_id,
      name: role.name,
      code: role.code,
      track: role.track,
      levels: role.levels.sort_by(&:ordinal).map { |l| build_level(l) }
    )
  end

  def build_level(level)
    Frameworks::ExplorerGraph::Level.new(
      level_id: level.level_id,
      role_id: level.role_id,
      ordinal: level.ordinal,
      title: level.title,
      code: level.code,
      is_entry: level.try(:is_entry) || false,
      added_in_draft: false
    )
  end

  def build_capability_categories
    @framework.capability_categories
      .includes(capabilities: [ :bindings, { expectations: :illustrations } ])
      .order(:ordinal)
      .map do |cat|
        Frameworks::ExplorerGraph::CapabilityCategory.new(
          category_id: cat.category_id,
          name: cat.name,
          description: cat.description,
          ordinal: cat.ordinal,
          deficit_threshold: cat.try(:deficit_threshold),
          overperformance_cap: cat.try(:overperformance_cap),
          status: cat.try(:status) || "active",
          capabilities: cat.capabilities.map { |c| build_capability(c) }
        )
      end
  end

  def build_capability(capability)
    Frameworks::ExplorerGraph::Capability.new(
      capability_id: capability.capability_id,
      stable_id: capability.stable_id,
      category_id: capability.category_id,
      name: capability.name,
      description: capability.description,
      status: capability.status,
      bindings: capability.bindings.map { |b| build_binding(b) },
      expectations: capability.expectations.sort_by(&:level_ordinal).map { |e| build_expectation(e) },
      added_in_draft: false,
      pending_archive: false
    )
  end

  def build_binding(binding_record)
    Frameworks::ExplorerGraph::CapabilityRoleBinding.new(
      binding_id: binding_record.binding_id,
      capability_id: binding_record.capability_id,
      role_id: binding_record.role_id,
      weight: binding_record.weight,
      individual_tolerance: binding_record.try(:individual_tolerance),
      added_in_draft: false
    )
  end

  def build_expectation(expectation)
    Frameworks::ExplorerGraph::BehaviouralExpectation.new(
      expectation_id: expectation.expectation_id,
      stable_id: expectation.stable_id,
      capability_id: expectation.capability_id,
      level_ordinal: expectation.level_ordinal,
      description: expectation.description,
      illustrations: expectation.illustrations.sort_by(&:ordinal).map { |i| build_illustration(i) },
      added_in_draft: false
    )
  end

  def build_illustration(illustration)
    Frameworks::ExplorerGraph::RoleIllustration.new(
      illustration_id: illustration.illustration_id,
      stable_id: illustration.stable_id,
      expectation_id: illustration.expectation_id,
      role_id: illustration.role_id,
      ordinal: illustration.ordinal,
      description: illustration.description
    )
  end
end
