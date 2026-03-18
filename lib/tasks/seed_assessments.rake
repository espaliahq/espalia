# frozen_string_literal: true

namespace :assessments do
  desc "Seed assessment data: link admin user to a Person, assign to framework, open cycle"
  task seed: :environment do
    tenant = Tenant.find_by!(slug: "meandu")

    ActsAsTenant.with_tenant(tenant) do
      framework = FrameworkState::Framework.first
      unless framework
        puts "No framework found. Run frameworks:seed_meandu first."
        next
      end

      admin_tu = TenantUser.find_by(role: "admin")
      unless admin_tu
        puts "No admin TenantUser found. Run db:seed first."
        next
      end

      # Skip if already seeded
      if PersonFrameworkAssignment.for_person(admin_tu.person_id).exists?
        puts "Assessment data already seeded. Skipping."
        next
      end

      # Create or find a Person for the admin user
      person = admin_tu.person
      unless person
        person = Person.create!(
          tenant: tenant,
          email: admin_tu.user.email,
          name: admin_tu.user.email.split("@").first.titleize,
          job_title: "Engineering Manager"
        )
        admin_tu.update!(person: person)
        puts "Created Person: #{person.name} (#{person.email})"
      end

      # Pick a role and level from the framework
      role = FrameworkState::Role.find_by(name: "Software Engineer")
      level = FrameworkState::Level.where(role_id: role.role_id, ordinal: 3).first
      unless role && level
        puts "No roles/levels found in framework. Skipping."
        next
      end

      puts "Assigning #{person.name} to framework '#{framework.name}' as #{role.name} at #{level.title}"

      handler = PersonDevelopment::CommandHandler.new
      handler.assign_to_framework(person.id, framework.framework_id, role.role_id, level.level_id)

      cycle_id = SecureRandom.uuid_v7
      puts "Opening assessment cycle: Q1 2026 Review"
      handler.open_assessment_cycle(
        person.id, framework.framework_id,
        cycle_id, "Q1 2026 Review", "regular", framework.current_published_version
      )

      # Pre-rate a few capabilities to demonstrate scoring
      bindings = FrameworkState::CapabilityRoleBinding.where(role_id: role.role_id)
        .includes(:capability).limit(3)

      bindings.each_with_index do |binding, i|
        cap = binding.capability
        frequency = %w[consistent occasional some][i % 3]
        puts "  Pre-rating #{cap.name} at L#{level.ordinal}: #{frequency}"
        handler.rate_self(
          person.id, framework.framework_id,
          cap.stable_id,
          level_ordinal: level.ordinal,
          frequency: frequency,
          comment: "Seeded self-rating"
        )
      end

      puts "Assessment seed complete."
    end
  end
end
