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

      report_person = Person.find_or_create_by!(email: report_email) do |p|
        p.tenant = tenant
        p.name = "Alex Developer"
        p.job_title = "Software Engineer"
        p.manager = manager_person
        puts "Created Person (report): Alex Developer (manager: #{manager_person.name})"
      end

      report_tu = TenantUser.find_or_create_by!(tenant: tenant, user: report_user) do |tu|
        tu.role = :member
        tu.person = report_person
        puts "Assigned #{report_email} to tenant #{tenant.name} as member"
      end
      report_tu.update!(person: report_person) if report_tu.person.nil?

      # Pick roles and levels from the framework
      role = FrameworkState::Role.find_by(name: "Software Engineer")
      level = FrameworkState::Level.where(role_id: role.role_id, ordinal: 3).first
      unless role && level
        puts "No Software Engineer role/levels found in framework. Skipping."
        next
      end

      mgr_role = FrameworkState::Role.find_by(name: "Engineering Manager")
      mgr_level = FrameworkState::Level.where(role_id: mgr_role.role_id, ordinal: 5).first

      handler = PersonDevelopment::CommandHandler.new
      cycle_handler = AssessmentCycles::CommandHandler.new

      # Assign the manager to the framework as Engineering Manager L5
      if mgr_role && mgr_level
        if PersonFrameworkAssignment.for_person(manager_person.id).where(framework_id: framework.framework_id).exists?
          puts "Manager already assigned to framework. Skipping."
        else
          puts "Assigning #{manager_person.name} to framework '#{framework.name}' as #{mgr_role.name} at #{mgr_level.title}"
          handler.assign_to_framework(manager_person.id, framework.framework_id, mgr_role.role_id, mgr_level.level_id)
        end
      else
        puts "Engineering Manager role or L5 level not found. Skipping manager assignment."
      end

      # Assign the direct report to the framework
      report_assignment = PersonFrameworkAssignment.for_person(report_person.id).where(framework_id: framework.framework_id).first
      if report_assignment
        puts "Report already assigned to framework. Skipping."
      else
        puts "Assigning #{report_person.name} to framework '#{framework.name}' as #{role.name} at #{level.title}"
        handler.assign_to_framework(report_person.id, framework.framework_id, role.role_id, level.level_id)
        report_assignment = PersonFrameworkAssignment.for_person(report_person.id).where(framework_id: framework.framework_id).first
      end

      # Define & enroll participants in an assessment cycle
      existing_open_cycle = AssessmentCycle.for_framework(framework.framework_id).open_cycles.first
      if existing_open_cycle
        puts "Open assessment cycle already exists: #{existing_open_cycle.name}. Skipping."
        cycle_id = existing_open_cycle.cycle_id
      else
        cycle_id = SecureRandom.uuid_v7
        puts "Defining assessment cycle: Q1 2026 Review"
        cycle_handler.define_cycle(
          cycle_id, framework.framework_id,
          "Q1 2026 Review", "regular", framework.current_published_version,
          defined_by: manager_person.id
        )
        puts "  Enrolling manager: #{manager_person.name}"
        cycle_handler.enroll(cycle_id, manager_person.id, enrolled_by: manager_person.id)
        puts "  Enrolling report: #{report_person.name}"
        cycle_handler.enroll(cycle_id, report_person.id, enrolled_by: manager_person.id)
      end

      # Pre-rate a few capabilities as self-ratings (from the report's perspective)
      bindings = FrameworkState::CapabilityRoleBinding.where(role_id: role.role_id)
        .includes(:capability).limit(3)

      existing_ratings = AssessmentLevelRating.for_person(report_person.id)
        .for_framework(framework.framework_id).for_cycle(cycle_id).self_rated
      if existing_ratings.exists?
        puts "Self-ratings already exist in cycle. Skipping."
      else
        bindings.each_with_index do |binding, i|
          cap = binding.capability
          frequency = %w[consistent occasional some][i % 3]
          puts "  Self-rating #{cap.name} at L#{level.ordinal}: #{frequency}"
          handler.rate_self(
            report_person.id, framework.framework_id,
            cap.stable_id,
            level_ordinal: level.ordinal,
            frequency: frequency,
            cycle_id: cycle_id,
            comment: "Seeded self-rating"
          )
        end
      end

      puts "Assessment seed complete."
      puts "  Manager: #{manager_person.name} (#{admin_tu.user.email})"
      puts "  Report:  #{report_person.name} (#{report_email} / password123)"
    end
  end
end
