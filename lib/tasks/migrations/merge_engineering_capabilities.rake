# frozen_string_literal: true

# One-shot operational migration that applies the engineering capability
# merge (see the seed YAML change in this same PR) to an already-seeded
# tenant's live framework.
#
# What it does, in order, against the tenant's single framework:
#
#   1. start_draft for current_published_version + 1
#   2. add DE + AE bindings to each of the four survivors (skips bindings
#      that already exist — safe to re-run after a partial failure):
#        - Cat 10 "Technical Expertise: Cloud Architecture & Infrastructure"
#        - Cat 11 "System Design & Architecture"
#        - Cat 11 "Quality First Mindset"
#        - Cat 11 "DevSecOps (Development, Security & Operations) Mindset"
#   3. archive_capability for each of the four Cat 8 duplicates
#   4. define_migration_mapping (type "same") for each archived cap →
#      its Cat 10/11 survivor, satisfying ADR-17's publish gate
#   5. archive_capability_category for the now-empty Cat 8
#   6. publish_version with reason "merge-engineering-capabilities"
#
# Guards:
#   - Refuses if the framework already has a draft in progress (manual
#     resolution required — don't want to nest changes into someone
#     else's in-flight draft).
#   - Refuses if any survivor is missing (could mean the framework was
#     seeded before the duplicates existed; nothing to merge).
#   - Idempotent on already-archived caps and existing bindings.
#
# Environment:
#   DRY_RUN=1  — prints the plan and exits without writing.
#
# Usage:
#   bin/rails 'frameworks:migrations:merge_engineering_capabilities[meandu]'
#   DRY_RUN=1 bin/rails 'frameworks:migrations:merge_engineering_capabilities[meandu]'

namespace :frameworks do
  namespace :migrations do
    desc "Merge duplicate engineering caps into single E/EM/DE/AE-bound entries"
    task :merge_engineering_capabilities, [ :tenant_slug ] => :environment do |_t, args|
      slug = args[:tenant_slug] || "meandu"
      dry_run = ENV["DRY_RUN"] == "1"

      tenant = Tenant.find_by!(slug: slug)
      puts "Tenant: #{tenant.name} (slug=#{tenant.slug}, id=#{tenant.id})"
      puts "Mode: #{dry_run ? 'DRY RUN — no events will be published' : 'LIVE'}"
      puts

      ActsAsTenant.with_tenant(tenant) do
        frameworks = FrameworkState::Framework.all.to_a
        if frameworks.size != 1
          abort "Expected exactly 1 framework for tenant #{tenant.slug}, found #{frameworks.size}. " \
                "Pass an explicit framework selector if/when this tenant holds multiple frameworks."
        end
        framework = frameworks.first
        puts "Framework: #{framework.name} (id=#{framework.framework_id}, v#{framework.current_published_version})"

        if framework.draft_in_progress
          abort "Framework already has a draft in progress (target v#{framework.draft_version}). Resolve manually."
        end

        plan = build_plan(framework)
        print_plan(framework, plan)

        if dry_run
          puts "\nDry run complete. Re-run without DRY_RUN=1 to apply."
          next
        end

        Rails.configuration.event_store.with_metadata(tenant_id: tenant.id) do
          execute_plan(framework, plan)
        end

        puts "\nMigration complete. Framework republished at v#{framework.reload.current_published_version}."
      end
    end
  end
end

# Capability merges, indexed by source category name.
#
# Each entry maps a Cat 8 duplicate (to be archived) to the surviving
# capability with the same name in another category. The target category
# is identified by name because IDs vary per-seed.
ENGINEERING_MERGES = [
  {
    source_category: "Engineering Capabilities",
    target_category: "Technical Expertise",
    capability_name: "Technical Expertise: Cloud Architecture & Infrastructure"
  },
  {
    source_category: "Engineering Capabilities",
    target_category: "Role Specific",
    capability_name: "System Design & Architecture"
  },
  {
    source_category: "Engineering Capabilities",
    target_category: "Role Specific",
    capability_name: "Quality First Mindset"
  },
  {
    source_category: "Engineering Capabilities",
    target_category: "Role Specific",
    capability_name: "DevSecOps (Development, Security & Operations) Mindset"
  }
].freeze

# Role codes to add to every surviving capability's bindings.
EXTRA_ROLE_CODES = %w[DE AE].freeze

# Builds the full migration plan without mutating anything.
#
# @param framework [FrameworkState::Framework]
# @return [Hash] plan with :pairs, :role_ids_to_add, :source_category
def build_plan(framework)
  source_category = find_category!(framework, ENGINEERING_MERGES.first[:source_category])

  pairs = ENGINEERING_MERGES.map do |merge|
    {
      archive: find_capability_in_category!(framework, merge[:source_category], merge[:capability_name]),
      survivor: find_capability_in_category!(framework, merge[:target_category], merge[:capability_name])
    }
  end

  role_ids_to_add = EXTRA_ROLE_CODES.map { |code| find_role!(framework, code) }

  { source_category: source_category, pairs: pairs, role_ids_to_add: role_ids_to_add }
end

def print_plan(framework, plan)
  target_version = framework.current_published_version + 1
  role_codes = plan[:role_ids_to_add].filter_map { |r| FrameworkState::Role.find_by(role_id: r)&.code }.join(", ")

  puts "\nPlan:"
  puts "  1. Open draft v#{target_version}"
  puts "  2. Add bindings for roles [#{role_codes}] to each of #{plan[:pairs].size} survivors (skip if already bound):"
  plan[:pairs].each { |pair| puts "       - #{pair[:survivor].name.inspect}" }
  puts "  3. Archive #{plan[:pairs].size} Cat 8 capability/capabilities:"
  plan[:pairs].each { |pair| puts "       - #{pair[:archive].name.inspect}" }
  puts "  4. Define migration mapping (type=same) for each archived stable_id -> its survivor"
  puts "  5. Archive category #{plan[:source_category].name.inspect}"
  puts "  6. Publish v#{target_version}"
end

def execute_plan(framework, plan)
  framework_id = framework.framework_id
  handler = Frameworks::CommandHandler.new
  target_version = framework.current_published_version + 1

  puts "\nStarting draft v#{target_version}..."
  handler.start_draft(framework_id, target_version, "merge-engineering-capabilities")

  puts "\nAdding bindings to survivors..."
  plan[:pairs].each do |pair|
    plan[:role_ids_to_add].each do |role_id|
      add_binding_if_missing(handler, framework_id, pair[:survivor].capability_id, role_id)
    end
  end

  puts "\nArchiving Cat 8 duplicates and defining migration mappings..."
  plan[:pairs].each do |pair|
    archive_capability_if_active(handler, framework_id, pair[:archive])
    define_mapping_if_missing(handler, framework_id, pair[:archive], pair[:survivor])
  end

  puts "\nArchiving now-empty category #{plan[:source_category].name.inspect}..."
  archive_category_if_active(handler, framework_id, plan[:source_category])

  puts "\nPublishing v#{target_version}..."
  handler.publish_version(framework_id, "merge-engineering-capabilities")
end

def archive_category_if_active(handler, framework_id, category)
  if category.status == "archived"
    puts "  already archived: #{category.name.inspect} — skipping"
    return
  end

  handler.archive_capability_category(framework_id, category.category_id,
    reason: "All capabilities merged into Technical Expertise / Role Specific")
  puts "  archived: #{category.name.inspect}"
end

def add_binding_if_missing(handler, framework_id, capability_id, role_id)
  existing = FrameworkState::CapabilityRoleBinding.find_by(capability_id: capability_id, role_id: role_id)
  if existing
    puts "  binding exists: cap=#{capability_id[0..7]}… role=#{role_id[0..7]}… — skipping"
    return
  end

  binding_id = SecureRandom.uuid_v7
  handler.create_capability_role_binding(framework_id, binding_id, capability_id, role_id)
  puts "  binding added:  cap=#{capability_id[0..7]}… role=#{role_id[0..7]}…"
end

def archive_capability_if_active(handler, framework_id, capability)
  if capability.status == "archived"
    puts "  already archived: #{capability.name.inspect} — skipping archive (mapping will be checked separately)"
    return
  end

  handler.archive_capability(framework_id, capability.capability_id,
    reason: "Merged with #{capability.category&.name || 'sibling'} survivor")
  puts "  archived: #{capability.name.inspect}"
end

# Avoids accumulating duplicate FrameworkState::MigrationMapping rows on
# reruns. The events table is the source of truth, but
# `MigrationMappingDefined` is in PublishedState's `skip_during_rebuild?`
# list and the read-model rows are not destroyed by
# `destroy_framework_children`, so a naive re-emit would add a second row
# pointing at the same from_stable_id and make subsequent lookups
# nondeterministic.
#
# Aborts rather than emits a second mapping when an existing row points
# somewhere else — two mappings for the same from_stable_id would leave
# rating migration ambiguous. The operator has to reconcile by hand.
def define_mapping_if_missing(handler, framework_id, archive_cap, survivor_cap)
  existing = FrameworkState::MigrationMapping.find_by(
    framework_id: framework_id, from_stable_id: archive_cap.stable_id
  )

  if existing
    if existing.to_stable_id == survivor_cap.stable_id && existing.mapping_type == "same"
      puts "  mapping exists: #{archive_cap.name.inspect} -> #{survivor_cap.name.inspect} (same) — skipping"
      return
    end

    abort(
      "Conflicting migration mapping for from_stable_id=#{archive_cap.stable_id}: " \
      "existing to=#{existing.to_stable_id} (#{existing.mapping_type}), " \
      "expected to=#{survivor_cap.stable_id} (same). Resolve manually before re-running."
    )
  end

  handler.define_migration_mapping(
    framework_id,
    SecureRandom.uuid_v7,
    archive_cap.stable_id,
    survivor_cap.stable_id,
    "same",
    reason: "Merged duplicate engineering capability"
  )
  puts "  mapping defined: #{archive_cap.name.inspect} -> #{survivor_cap.name.inspect} (same)"
end

def find_category!(framework, name)
  framework.capability_categories.find_by(name: name) ||
    abort("Category #{name.inspect} not found in framework #{framework.framework_id}. Nothing to migrate.")
end

def find_capability_in_category!(framework, category_name, capability_name)
  category = find_category!(framework, category_name)
  category.capabilities.find_by(name: capability_name) ||
    abort("Capability #{capability_name.inspect} not found in category #{category_name.inspect}. " \
          "Has the framework been migrated already, or never had the duplicates?")
end

def find_role!(framework, code)
  role = framework.role_families.flat_map(&:roles).find { |r| r.code == code }
  role&.role_id || abort("Role with code #{code.inspect} not found in framework. Cannot add binding.")
end
