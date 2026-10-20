# frozen_string_literal: true

# Force line-buffered stdout so seed progress shows up live under Render's
# log collector (Ruby's default block-buffers stdout when it isn't a TTY,
# which hides multi-minute seed runs until the process exits).
$stdout.sync = true

# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).
#
# Example:
#
#   ["Action", "Comedy", "Drama", "Horror"].each do |genre_name|
#     MovieGenre.find_or_create_by!(name: genre_name)
#   end

[ Rails.application.credentials.admin.user_1 ].each do |admin_user_credentials|
  admin_user = User.where(email: admin_user_credentials.email).first
  if admin_user.nil?
    puts "Creating admin user: #{admin_user_credentials.email}"
    admin_user = User.new(
      email: admin_user_credentials.email,
      # name: admin_user_credentials.name,
      global_admin: true,
      password: admin_user_credentials.password,
      password_confirmation: admin_user_credentials.password
    )
    admin_user.save!
  else
    puts "Admin user #{admin_user_credentials.email} already exists"
  end

  [
    { slug: "meandu", name: "me&u", theme: "custom", font_family: "Zalando Sans Regular",
      custom_theme: { "brand" => { "light" => "#00362F", "dark" => "#5ee0a0" },
                      "nav-surface" => { "light" => "#DBFC45", "dark" => "#0a1f1a" } } },
    { slug: "testco", name: "Testco", theme: "custom", font_family: "Poppins",
      custom_theme: { "brand" => { "light" => "#6366f1", "dark" => "#818cf8" },
                      "nav-surface" => { "light" => "#1e1b4b", "dark" => "#0f0d2e" } } }
  ].each do |tenant_attrs|
    theme_attrs = tenant_attrs.slice(:theme, :custom_theme, :font_family)

    tenant = Tenant.find_or_create_by!(slug: tenant_attrs[:slug]) do |t|
      t.name = tenant_attrs[:name]
      t.assign_attributes(theme_attrs)
      puts "Creating tenant: #{tenant_attrs[:name]}"
    end

    # Update theme on existing tenants
    tenant.assign_attributes(theme_attrs)
    if tenant.changed?
      tenant.save!
      puts "Updated theme for #{tenant_attrs[:name]}"
    end

    ActsAsTenant.with_tenant(tenant) do
      unless TenantUser.exists?(user: admin_user)
        TenantUser.create!(tenant: tenant, user: admin_user, role: :admin)
        puts "Assigned #{admin_user.email} to tenant #{tenant_attrs[:name]} as admin"
      else
        puts "#{admin_user.email} already assigned to tenant #{tenant_attrs[:name]}"
      end
    end
  end
end

# Seed framework data (must run BEFORE HRIS sync so Pass 5 has a framework to assign to)
Rake::Task["frameworks:seed_meandu"].invoke

# Seed pending suggestions for visual affordance testing — dev/test only.
# Production seeds must never surface demo editorial state to real tenants.
meandu_tenant = Rails.env.production? ? nil : Tenant.find_by(slug: "meandu")
if meandu_tenant
  ActsAsTenant.with_tenant(meandu_tenant) do
    framework = FrameworkState::Framework.first
    if framework && FrameworkState::SuggestedEdit.where(framework_id: framework.framework_id).none?
      # Transaction keeps re-runs safe — partial failure rolls back rather
      # than leaving the guard's `.none?` predicate false forever.
      ActiveRecord::Base.transaction do
      handler = Frameworks::CommandHandler.new
      admin_user = User.find_by(global_admin: true)
      raise "No global admin user found — cannot seed suggestions" unless admin_user

      # framework_suggested_edits.author_id is a foreign key to people(id).
      # TenantUser#ensure_person! is the shared invariant helper — it links
      # an existing email-matched Person, or bootstraps a minimal one when
      # the admin has never been provisioned via HRIS.
      admin_person = TenantUser.find_by(user_id: admin_user.id)&.ensure_person!
      raise "Admin user has no TenantUser in meandu tenant — cannot seed suggestions" unless admin_person

      admin_author_id = admin_person.id.to_s

      # Grab sample entities from the seeded framework
      category = framework.capability_categories.first
      capability = category&.capabilities&.first
      expectation = capability&.expectations&.first
      illustration = expectation&.illustrations&.first

      if expectation && illustration
        puts "Seeding pending suggestions for visual affordance testing..."

        # Pending edit on a behavioural_expectation
        handler.suggest_edit(
          framework.framework_id, SecureRandom.uuid_v7,
          "behavioural_expectation", expectation.expectation_id,
          "description", "Consistently asks clarifying questions to uncover hidden assumptions",
          admin_author_id, rationale: "More specific wording",
          mode: :suggesting
        )

        # Pending edit on a role_illustration
        handler.suggest_edit(
          framework.framework_id, SecureRandom.uuid_v7,
          "role_illustration", illustration.illustration_id,
          "description", "Identifies and escalates unclear requirements before starting work",
          admin_author_id, rationale: "Better real-world example",
          mode: :suggesting
        )

        # Pending edit on a capability name
        handler.suggest_edit(
          framework.framework_id, SecureRandom.uuid_v7,
          "capability", capability.capability_id,
          "name", "#{capability.name} & Problem Solving",
          admin_author_id, rationale: "Broaden the scope",
          mode: :suggesting
        )

        # Pending edit on a capability_category name
        handler.suggest_edit(
          framework.framework_id, SecureRandom.uuid_v7,
          "capability_category", category.category_id,
          "name", "#{category.name} (Revised)",
          admin_author_id, rationale: "Clarify category scope",
          mode: :suggesting
        )

        # Pending create for a role_illustration
        role = FrameworkState::Role.first
        if role
          handler.suggest_create(
            framework.framework_id, SecureRandom.uuid_v7,
            "role_illustration",
            { role_id: role.role_id, description: "Proposes alternative solutions when blocked" },
            parent_id: expectation.expectation_id,
            author_id: admin_author_id,
            mode: :suggesting
          )
        end

        # Pending delete for a role_illustration (if there's a second illustration)
        second_illustration = expectation.illustrations.second
        if second_illustration
          handler.suggest_delete(
            framework.framework_id, SecureRandom.uuid_v7,
            "role_illustration", second_illustration.illustration_id,
            author_id: admin_author_id, rationale: "Redundant with first example",
            mode: :suggesting
          )
        end

        puts "  Seeded #{FrameworkState::SuggestedEdit.where(framework_id: framework.framework_id).pending.count} pending suggestions"
      else
        puts "Skipping suggestion seeding — framework entities not ready"
      end
      end # transaction
    else
      puts "Suggestions already seeded or no framework found"
    end
  end
end

# Seed assessment demo data (person assignment, open cycle, sample
# evidence + comments). Dev/test only — production tenants must never
# receive a demo "Alex Developer" report, demo ratings, or seeded
# evidence/comments. The framework seed above runs in all environments
# because it's the tenant's actual content; the assessment fixtures
# below are demo scaffolding for local development and CI only.
if Rails.env.development? || Rails.env.test?
  Rake::Task["assessments:seed"].invoke
else
  puts "Skipping assessments:seed in #{Rails.env} (demo fixtures are dev/test-only)"
end

# Seed HRIS config for me&u tenant
meandu = Tenant.find_by(slug: "meandu")
if meandu && Rails.application.credentials.dig(:hris, :hibob, :meandu)
  hibob_creds = Rails.application.credentials.dig(:hris, :hibob, :meandu)

  meandu_role_mappings = [
    HrisRoleMapping.new(
      framework_role_code: "E",
      hris_titles: [
        "Software Engineer II",
        "Senior Software Engineer",
        "Staff Software Engineer",
        "Staff Engineer",
        "Senior Staff Engineer",
        "Principal Engineer",
        "Site Reliability Engineer",
        "Example Principal Engineer Title"
      ]
    ),
    HrisRoleMapping.new(
      framework_role_code: "EM",
      hris_titles: [
        "Engineering Manager",
        "Senior Engineering Manager",
        "Example Engineering Director Title"
      ]
    ),
    HrisRoleMapping.new(
      framework_role_code: "PD",
      hris_titles: [ "Product Designer", "Senior Product Designer" ]
    ),
    HrisRoleMapping.new(
      framework_role_code: "PM",
      hris_titles: [
        "Product Manager",
        "Senior Product Manager",
        "Group Product Manager",
        "Example Product Director Title"
      ]
    ),
    HrisRoleMapping.new(
      framework_role_code: "AE",
      hris_titles: [ "Analytics Engineer" ]
    ),
    HrisRoleMapping.new(
      framework_role_code: "DE",
      hris_titles: [ "Staff Data Engineer" ]
    ),
    HrisRoleMapping.new(
      framework_role_code: "FC",
      hris_titles: [
        "Accountant",
        "Senior Accountant",
        "Senior Management Accountant",
        "Accounting Manager"
      ]
    ),
    HrisRoleMapping.new(
      framework_role_code: "CF",
      hris_titles: [ "Senior Commercial Finance Manager" ]
    ),
    HrisRoleMapping.new(
      framework_role_code: "FO",
      hris_titles: [ "Example Finance Operations Title", "Example Finance Manager Title" ]
    ),
    HrisRoleMapping.new(
      framework_role_code: "FCo",
      hris_titles: [ "Financial Controller" ]
    )
  ]

  meandu.update!(
    hris_config: HrisConfig.new(
      provider: "hibob",
      sync_enabled: true,
      level_field_id: "column_0000000000000",
      role_mappings: meandu_role_mappings
    ),
    hris_credentials: {
      "service_user_id" => hibob_creds.service_user_id,
      "api_token" => hibob_creds.api_token
    }
  )
  puts "Configured HiBob HRIS integration for me&u"

  # Run an initial sync in development so the seeded tenant has real people data
  if Rails.env.development?
    puts "Running initial HiBob sync for me&u..."
    result = Hris::Hibob::Adapter.new(meandu).sync_people
    puts "  Sync complete: created=#{result[:created]} updated=#{result[:updated]} " \
         "deactivated=#{result[:deactivated]} errors=#{result[:errors].size}"
    puts "  Framework assignments: assigned=#{result[:assigned]} " \
         "role_changed=#{result[:role_changed]} level_changed=#{result[:level_changed]} " \
         "unchanged=#{result[:unchanged]}"
    puts "  Unmapped titles: #{result[:unmapped_titles].to_a.sort.join(', ')}" if result[:unmapped_titles].any?
    puts "  Missing levels: #{result[:missing_levels].to_a.inspect}" if result[:missing_levels].any?
    puts "  Missing ordinals: #{result[:missing_ordinals].size} people" if result[:missing_ordinals].any?

    # Population-wide demo ratings/evidence so the calibration surfaces
    # (tendency strip, divergence board, drill-in) have realistic data.
    # Runs AFTER the HRIS sync — the population only exists once people
    # are assigned and auto-enrolled. Development-only; the task hard-aborts
    # anywhere else. Deterministic + idempotent, so re-seeding converges.
    puts "Seeding population-wide calibration activity..."
    Rake::Task["assessments:seed_calibration_activity"].invoke
  end
else
  puts "Skipping HiBob HRIS config (no credentials in Rails credentials file)"
end
