# frozen_string_literal: true

namespace :assessments do
  desc "Seed assessment data: link admin user to a Person, assign to framework, open cycle, create manager"
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

      # Create or find a Person for the admin user (this will be the manager)
      manager_person = admin_tu.person
      unless manager_person
        manager_person = Person.create!(
          tenant: tenant,
          email: admin_tu.user.email,
          name: admin_tu.user.email.split("@").first.titleize,
          job_title: "Engineering Manager"
        )
        admin_tu.update!(person: manager_person)
        puts "Created Person (manager): #{manager_person.name} (#{manager_person.email})"
      end

      # Create a direct report Person + User for manager rating workflow
      report_email = "report@#{tenant.slug}.example.com"
      report_user = User.find_or_create_by!(email: report_email) do |u|
        u.password = "password123"
        u.password_confirmation = "password123"
        puts "Created report User: #{report_email}"
      end

      report_person = Person.find_by(email: report_email)
      unless report_person
        report_person = Person.create!(
          tenant: tenant,
          email: report_email,
          name: "Alex Developer",
          job_title: "Software Engineer",
          manager: manager_person
        )
        puts "Created Person (report): #{report_person.name} (manager: #{manager_person.name})"
      end

      report_tu = TenantUser.find_or_create_by!(tenant: tenant, user: report_user) do |tu|
        tu.role = :member
        tu.person = report_person
        puts "Assigned #{report_email} to tenant #{tenant.name} as member"
      end
      report_tu.update!(person: report_person) if report_tu.person.nil?

      # Pick a role and level from the framework
      role = FrameworkState::Role.find_by(name: "Software Engineer")
      level = FrameworkState::Level.where(role_id: role.role_id, ordinal: 3).first
      unless role && level
        puts "No roles/levels found in framework. Skipping."
        next
      end

      # Assign the direct report to the framework
      puts "Assigning #{report_person.name} to framework '#{framework.name}' as #{role.name} at #{level.title}"

      handler = PersonDevelopment::CommandHandler.new
      handler.assign_to_framework(report_person.id, framework.framework_id, role.role_id, level.level_id)

      cycle_id = SecureRandom.uuid_v7
      puts "Opening assessment cycle: Q1 2026 Review"
      handler.open_assessment_cycle(
        report_person.id, framework.framework_id,
        cycle_id, "Q1 2026 Review", "regular", framework.current_published_version
      )

      # Pre-rate a few capabilities as self-ratings (from the report's perspective)
      bindings = FrameworkState::CapabilityRoleBinding.where(role_id: role.role_id)
        .includes(:capability).limit(3)

      bindings.each_with_index do |binding, i|
        cap = binding.capability
        frequency = %w[consistent occasional some][i % 3]
        puts "  Self-rating #{cap.name} at L#{level.ordinal}: #{frequency}"
        handler.rate_self(
          report_person.id, framework.framework_id,
          cap.stable_id,
          level_ordinal: level.ordinal,
          frequency: frequency,
          comment: "Seeded self-rating"
        )
      end

      puts "Assessment seed complete."
      puts "  Manager: #{manager_person.name} (#{admin_tu.user.email})"
      puts "  Report:  #{report_person.name} (#{report_email} / password123)"
    end
  end
end
