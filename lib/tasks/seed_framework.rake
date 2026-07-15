# frozen_string_literal: true

namespace :frameworks do
  desc "Seed the me&u career framework from YAML via RailsEventStore events"
  task seed_meandu: :environment do
    require "yaml"

    yaml_path = Rails.root.join("db/seeds/meandu_career_framework.yml")
    data = YAML.load_file(yaml_path)
    framework_data = data["framework"]

    tenant = Tenant.find_by!(slug: "meandu")
    framework_id = SecureRandom.uuid_v7

    ActsAsTenant.with_tenant(tenant) do
      handler = Frameworks::CommandHandler.new

      # Check if framework already seeded
      if FrameworkState::Framework.count > 0
        puts "Framework already seeded for me&u tenant. Skipping."
        next
      end

      puts "Creating framework: #{framework_data['name']}"

      # Collect post-publish read-model mutations (deficit_threshold) because the
      # publish-time rebuild will wipe child read models and replay events from
      # the stream — direct read-model writes made during the draft would be
      # lost. Applied after publish. (Department is now event-sourced on
      # add_role_family, so it needs no deferral.)
      pending_category_threshold_updates = [] # [[category_id, deficit_threshold], ...]

      # ── Role Families, Roles, Levels ──
      role_code_to_id = {}   # "E" => uuid, "DE" => uuid
      role_name_to_id = {}   # "Product Designer" => uuid (scope resolution — read
      #                        models don't exist yet inside the batch)
      level_code_to_id = {}  # "E1" => uuid
      all_role_ids = []
      management_role_ids = []
      finance_role_ids = []
      finance_role_codes = %w[FC FCo CF FO]

      cap_count = 0
      exp_count = 0
      ill_count = 0
      binding_count = 0

      # One unit of work for the whole build: a single aggregate load, one
      # event append, one ExplorerGraph write. Dispatching each of the ~1,600
      # commands individually re-replays the ever-growing stream and rewrites
      # the graph snapshot per command — O(N²), ~3 minutes for this seed.
      #
      # create_framework implicitly opens a v1 bootstrap draft. Shape-changing
      # events (add_capability, add_level, set_behavioural_expectation, etc.)
      # emitted before publish_version are deferred in the published projection
      # and replayed in bulk on publish. Editorial events (add_role_family,
      # add_capability_category, etc.) apply live.
      handler.batch(framework_id) do
        handler.create_framework(framework_id, framework_data["name"])

        framework_data["role_families"].select { |rf| rf["roles"] }.each do |rf_data|
          rfid = SecureRandom.uuid_v7
          puts "  Role family: #{rf_data['name']}"
          handler.add_role_family(
            framework_id, rfid, rf_data["name"],
            description: rf_data["description"], department: rf_data["department"]
          )

          rf_data["roles"].each do |role_data|
            rid = SecureRandom.uuid_v7
            handler.add_role(framework_id, rid, rfid, role_data["name"], role_data["code"], role_data["track"])
            role_code_to_id[role_data["code"]] = rid
            role_name_to_id[role_data["name"]] = rid
            all_role_ids << rid
            management_role_ids << rid if role_data["track"] == "management"
            finance_role_ids << rid if finance_role_codes.include?(role_data["code"])

            role_data["levels"]&.each do |level_data|
              lid = SecureRandom.uuid_v7
              handler.add_level(framework_id, lid, rid,
                level_data["ordinal"], level_data["title"], level_data["code"],
                is_entry: level_data["ordinal"] == role_data["levels"].map { |l| l["ordinal"] }.min)
              level_code_to_id[level_data["code"]] = lid
            end
          end
        end

        puts "  Loaded #{role_code_to_id.size} roles, #{level_code_to_id.size} levels"

        # ── Capability Categories, Capabilities, Bindings, Expectations, Illustrations ──
        framework_data["capability_categories"]&.each_with_index do |cat_data, cat_idx|
          cat_id = SecureRandom.uuid_v7
          puts "  Category: #{cat_data['name']}"
          handler.add_capability_category(framework_id, cat_id, cat_data["name"],
            description: cat_data["description"], ordinal: cat_idx + 1)

          # Defer: deficit_threshold lives on the read model only and the row
          # doesn't exist yet during the draft phase.
          if cat_data.key?("deficit_threshold")
            pending_category_threshold_updates << [ cat_id, cat_data["deficit_threshold"] ]
          end

          cat_data["capabilities"]&.each do |cap_data|
            cap_id = SecureRandom.uuid_v7
            stable_id = SecureRandom.uuid_v7
            handler.add_capability(framework_id, cap_id, stable_id, cat_id,
              cap_data["name"], description: cap_data["description"])
            cap_count += 1

            # Resolve scope to role IDs for bindings
            target_role_ids = resolve_scope(cap_data["scope"], role_code_to_id, role_name_to_id,
              all_role_ids, management_role_ids, finance_role_ids)

            individual_tolerance = cap_data.key?("individual_tolerance") ? cap_data["individual_tolerance"] : nil

            target_role_ids.each do |target_rid|
              bid = SecureRandom.uuid_v7
              handler.create_capability_role_binding(framework_id, bid, cap_id, target_rid,
                individual_tolerance: individual_tolerance)
              binding_count += 1
            end

            # Expectations and illustrations
            cap_data["expectations"]&.each do |exp_data|
              eid = SecureRandom.uuid_v7
              exp_stable_id = SecureRandom.uuid_v7
              handler.set_behavioural_expectation(framework_id, eid, exp_stable_id,
                cap_id, exp_data["level"], exp_data["description"])
              exp_count += 1

              exp_data["illustrations"]&.each_with_index do |ill_data, ill_idx|
                role_code = resolve_role_code(ill_data["role_code"], role_code_to_id)
                target_rid = role_code_to_id[role_code]

                unless target_rid
                  puts "    WARNING: Unknown role_code '#{ill_data['role_code']}' — skipping illustration"
                  next
                end

                iid = SecureRandom.uuid_v7
                ill_stable_id = SecureRandom.uuid_v7
                handler.add_role_illustration(framework_id, iid, ill_stable_id,
                  eid, target_rid, ill_idx + 1, ill_data["description"])
                ill_count += 1
              end
            end
          end
        end
      end

      # Publish the v1 draft — triggers rebuild_framework_projection which
      # replays all structural events and materialises the read models. On a
      # full seed (~1600 events) this takes a noticeable beat.
      puts "Publishing v1"
      handler.publish_version(framework_id, "seed")

      # Apply deferred read-model mutations now that the rebuild has created
      # the rows. find_by!/find_by raise/return nil if the rebuild didn't
      # materialise something expected — that's a desired loud failure.
      pending_category_threshold_updates.each do |cat_id, threshold|
        FrameworkState::CapabilityCategory.find_by!(category_id: cat_id)
          .update!(deficit_threshold: threshold)
      end

      # deficit_threshold was applied directly to the AR read model after
      # publish — the aggregate-based snapshot written during publish doesn't
      # see it. Rebuild the snapshot so the explorer graph reflects the final
      # seeded state. (Department is event-sourced, so it's already in the
      # snapshot from publish.)
      Frameworks::ExplorerGraph.rebuild(framework_id)

      puts "\nSeed complete!"
      puts "  Framework: #{framework_data['name']}"
      puts "  Role families: #{framework_data['role_families'].count { |rf| rf['roles'] }}"
      puts "  Roles: #{role_code_to_id.size}"
      puts "  Levels: #{level_code_to_id.size}"
      puts "  Capabilities: #{cap_count}"
      puts "  Bindings: #{binding_count}"
      puts "  Expectations: #{exp_count}"
      puts "  Illustrations: #{ill_count}"

      stream = EventStreamNaming.framework_stream(framework_id)
      total_events = Rails.configuration.event_store.read.stream(stream).count
      puts "  Total events in stream: #{total_events}"
    end
  end
end

# Resolves a YAML scope value to an array of role UUIDs.
#
# @param scope [String, Array, nil] the scope value from YAML
# @param role_code_to_id [Hash] mapping of role codes to UUIDs
# @param role_name_to_id [Hash] mapping of role names to UUIDs
# @param all_role_ids [Array] all role UUIDs
# @param management_role_ids [Array] management-track role UUIDs
# @param finance_role_ids [Array] finance role UUIDs
# @return [Array<String>] target role UUIDs
def resolve_scope(scope, role_code_to_id, role_name_to_id, all_role_ids, management_role_ids, finance_role_ids)
  case scope
  when "core"
    all_role_ids
  when "leadership"
    management_role_ids
  when "stream_leadership"
    # EM (Engineering Manager) — stream-level engineering leadership
    [ role_code_to_id["EM"] ].compact
  when "finance"
    finance_role_ids
  when "finance_leadership"
    finance_role_ids
  when String
    # Specific role name — resolved from the YAML-built map, NOT the read
    # model: inside the seed batch the projections haven't run yet, so
    # FrameworkState::Role rows don't exist.
    [ role_name_to_id[scope] ].compact
  when Array
    scope.flat_map { |s| role_name_to_id[s] }.compact
  else
    all_role_ids # default to all if no scope
  end
end

# Resolves a YAML role_code to just the role code portion.
# Some codes include the level ordinal (e.g. "AE1" → "AE", "DE3" → "DE")
# while others are just the role code (e.g. "PD", "FC").
#
# @param yaml_role_code [String] the role_code from YAML
# @param role_code_to_id [Hash] mapping of role codes to UUIDs
# @return [String] the role code
def resolve_role_code(yaml_role_code, role_code_to_id)
  # If it's an exact match, use it directly
  return yaml_role_code if role_code_to_id.key?(yaml_role_code)

  # Strip trailing digits to get the role code (e.g. "AE1" → "AE", "DM4" → "DM")
  base_code = yaml_role_code.sub(/\d+$/, "")
  return base_code if role_code_to_id.key?(base_code)

  # Fallback: return as-is
  yaml_role_code
end
