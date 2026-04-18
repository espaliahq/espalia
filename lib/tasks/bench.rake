# frozen_string_literal: true

# One-shot diagnostic benchmark for the "in-memory replay" approach to
# the Framework Explorer edit mode (option A). Not a CI test; measures
# aggregate-load latency for a seeded framework. See
# /home/vscode/.claude/plans/read-through-docs-guidelines-framework-e-unified-stallman.md
namespace :bench do
  desc "Benchmark Frameworks::Repository.with_framework aggregate load (L1). " \
       "Pass FRAMEWORK_ID=<uuid> to bench a specific framework, otherwise uses the first."
  task framework_replay: :environment do
    iterations = Integer(ENV.fetch("ITERATIONS", "25"))
    warmup = Integer(ENV.fetch("WARMUP", "3"))
    framework_id_override = ENV["FRAMEWORK_ID"].presence

    tenant = Tenant.find_by!(slug: "meandu")
    ActsAsTenant.with_tenant(tenant) do
      framework =
        if framework_id_override
          FrameworkState::Framework.find_by!(framework_id: framework_id_override)
        else
          FrameworkState::Framework.first
        end
      raise "No framework seeded — run bin/rails db:seed first" unless framework

      framework_id = framework.framework_id
      stream = EventStreamNaming.framework_stream(framework_id)
      event_count = Rails.configuration.event_store.read.stream(stream).count

      repo = Frameworks::Repository.new

      warmup.times { repo.with_framework(framework_id) { |a| a } }

      samples = Array.new(iterations) do
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        repo.with_framework(framework_id) { |a| a }
        ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round(3)
      end

      sorted = samples.sort
      p50 = sorted[sorted.size / 2]
      p95 = sorted[(sorted.size * 0.95).floor]
      max = sorted.last
      mean = (samples.sum / samples.size.to_f).round(3)

      puts "Framework: #{framework.name} (#{framework_id})"
      puts "Stream events: #{event_count}"
      puts "Iterations: #{iterations} (warmup #{warmup})"
      puts format("p50=%.2fms  p95=%.2fms  max=%.2fms  mean=%.2fms", p50, p95, max, mean)
      puts format("Throughput: %.1f events/ms (p50)", event_count / p50.to_f)
    end
  end

  desc "Build a synthetic framework with SIZE=small|medium|large (for benchmarking). " \
       "Prints the new framework_id. One-shot diagnostic; creates events that persist."
  task fatten_framework: :environment do
    size = ENV.fetch("SIZE", "medium")
    # Size targets rough event counts: small≈1500, medium≈5000, large≈12000.
    # Each capability contributes ~(bindings + expectations×(1+illustrations)) events.
    profile = case size
    when "small"  then { roles: 4,  levels: 5, categories: 6,  caps_per_cat: 4, exps_per_cap: 4, ills_per_exp: 2 }
    when "medium" then { roles: 16, levels: 8, categories: 12, caps_per_cat: 10, exps_per_cap: 6, ills_per_exp: 5 }
    when "large"  then { roles: 24, levels: 8, categories: 16, caps_per_cat: 12, exps_per_cap: 8, ills_per_exp: 6 }
    else raise "Unknown SIZE=#{size}"
    end

    tenant = Tenant.find_by!(slug: "meandu")
    framework_id = SecureRandom.uuid_v7
    rfid = SecureRandom.uuid_v7

    ActsAsTenant.with_tenant(tenant) do
      repo = Frameworks::Repository.new
      # Batch all structural commands inside one with_framework block so the
      # aggregate is loaded and saved once. Using CommandHandler per-call would
      # be O(n^2) in stream length — prohibitive at medium/large size.
      repo.with_framework(framework_id) do |framework|
        framework.create(framework_id, "Bench #{size} #{framework_id[0, 8]}")
        framework.add_role_family(framework_id, rfid, "Engineering", description: "Bench")

        role_ids = []
        profile[:roles].times do |r|
          rid = SecureRandom.uuid_v7
          framework.add_role(framework_id, rid, rfid, "Role #{r + 1}", "R#{r + 1}", "ic")
          role_ids << rid
          profile[:levels].times do |l|
            lid = SecureRandom.uuid_v7
            framework.add_level(framework_id, lid, rid, l + 1, "Level #{l + 1}", "R#{r + 1}L#{l + 1}", is_entry: l.zero?)
          end
        end

        profile[:categories].times do |c|
          cat_id = SecureRandom.uuid_v7
          framework.add_capability_category(framework_id, cat_id, "Category #{c + 1}", description: "d", ordinal: c + 1)

          profile[:caps_per_cat].times do |cp|
            cap_id = SecureRandom.uuid_v7
            stable_id = SecureRandom.uuid_v7
            framework.add_capability(framework_id, cap_id, stable_id, cat_id, "Cap #{c + 1}.#{cp + 1}", description: "d")

            role_ids.each do |target_rid|
              bid = SecureRandom.uuid_v7
              framework.create_capability_role_binding(framework_id, bid, cap_id, target_rid, individual_tolerance: nil)
            end

            profile[:exps_per_cap].times do |e|
              eid = SecureRandom.uuid_v7
              exp_stable_id = SecureRandom.uuid_v7
              framework.set_behavioural_expectation(framework_id, eid, exp_stable_id, cap_id, e + 1, "Expectation text #{e + 1}")

              role_ids.first(profile[:ills_per_exp]).each_with_index do |target_rid, i|
                iid = SecureRandom.uuid_v7
                ill_stable_id = SecureRandom.uuid_v7
                framework.add_role_illustration(framework_id, iid, ill_stable_id, eid, target_rid, i + 1, "illustration")
              end
            end
          end
        end
      end

      # Publish must be a separate with_framework block because the projection
      # subscribes to FrameworkVersionPublished and rebuilds — it needs to see
      # events that are already persisted.
      Frameworks::CommandHandler.new.publish_version(framework_id, "bench")

      stream = EventStreamNaming.framework_stream(framework_id)
      count = Rails.configuration.event_store.read.stream(stream).count
      puts "Built synthetic framework size=#{size} framework_id=#{framework_id} events=#{count}"
      puts "Re-run bench with: FRAMEWORK_ID=#{framework_id} bin/rails bench:framework_replay"
    end
  end
end
