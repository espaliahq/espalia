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

      # Seed a small mix of evidence items so the dev environment exercises
      # the full evidence/activity-feed surface: in-cell badge counts, the
      # expanded-cell list, source variety (self / manager), external links,
      # and a withdrawn item for the activity feed's strikethrough state.
      #
      # The gate checks for the first seeded title (rather than "any evidence
      # exists for this report") so manually-added evidence in dev doesn't
      # block the rest of the seed from filling out the demo set.
      # Seeded titles (and content) are written to clearly demonstrate the
      # *behavioural expectation* for each (capability, level) — not just
      # the capability label — so a reviewer browsing the dev assessment
      # can see the link between an evidence card and the exact L2/L3
      # behaviour it's evidence for. The expectations being demonstrated
      # are noted alongside each seed for future maintainers.
      seed_marker_title = "Auth migration RFC: weighed three approaches"
      already_seeded = EvidenceItem.for_person(report_person.id)
        .for_framework(framework.framework_id)
        .where(title: seed_marker_title)
        .exists?
      if already_seeded
        puts "Seeded evidence already present for report. Skipping evidence seed."
      else
        evidence_seeds = [
          # Strategic & Critical Thinking — L3:
          # "Breaks down problems, weighs options, and explains reasoning."
          {
            binding_index: 0, level_offset: 0, source: "self", author: report_person,
            type: "project_outcome",
            title: "Auth migration RFC: weighed three approaches",
            content: "Wrote a 4-page RFC breaking down the SAML vs OIDC vs hybrid migration paths. " \
                     "Built a decision matrix on rollout risk, vendor lock-in, and ops cost, " \
                     "walked the team through the trade-offs, and landed on phased OIDC with " \
                     "a clear written rationale.",
            external_reference: { system: "notion", url: "https://notion.example/auth-rfc" }
          },
          # Strategic & Critical Thinking — L3 (manager perspective on the
          # same expectation: breaks down problems, weighs options, explains
          # reasoning — surfaced in a code review).
          {
            binding_index: 0, level_offset: 0, source: "manager", author: manager_person,
            type: "code_review",
            title: "PR review: identified hidden coupling and proposed alternatives",
            content: "On the payments refactor PR, broke down why the proposed callback chain " \
                     "would create implicit ordering dependencies. Laid out two alternative " \
                     "service-object splits with the trade-offs and explained which one fit " \
                     "our existing module boundaries best.",
            external_reference: { system: "github", url: "https://github.com/example/repo/pull/427" }
          },
          # Data Informed & Customer Centric Decisions — L3:
          # "Combines insights and customer context to shape recommendations
          # and explain decisions."
          {
            binding_index: 1, level_offset: 0, source: "manager", author: manager_person,
            type: "customer_feedback",
            title: "Migration UX recommendation backed by partner research",
            content: "At the venue partner sync, combined qualitative interviews from three " \
                     "design partners with weekly retention metrics to recommend the simplified " \
                     "migration UX. Two partners said it was the clearest case they'd seen this " \
                     "quarter, and the team adopted the recommendation for the Q1 plan.",
            external_reference: nil
          },
          # Data Informed & Customer Centric Decisions — L2:
          # "Seeks out data or feedback to inform choices and considers how
          # the customer will be impacted."
          {
            binding_index: 1, level_offset: -1, source: "self", author: report_person,
            type: "other", custom_type_label: "Sprint planning input",
            title: "Pulled CS pain points before sprint sizing",
            content: "Before sizing the next sprint, reached out to Customer Success for the " \
                     "top three pain points from the past quarter. Folded the feedback into " \
                     "the priority ordering — bumped the import-failure log feature ahead of " \
                     "export polish because it was hitting onboarding the hardest.",
            external_reference: nil
          },
          # Commit, Deliver, Celebrate: Accountability & Execution — L3:
          # "Takes ownership of work (goals and projects etc) and proactively
          # clears blockers."
          {
            binding_index: 2, level_offset: 0, source: "self", author: report_person,
            type: "incident_response",
            title: "Saturday outage: rolled back inside SLO and ran the postmortem",
            content: "Took primary on-call for the storage-tier outage. Diagnosed the failure " \
                     "mode within 12 minutes, drove the rollback decision, kept stakeholders " \
                     "updated in #incidents every five minutes, and shipped the rollback inside " \
                     "the 30-minute SLO. Followed up Monday with a postmortem and three concrete " \
                     "prevention items, then drove two of them to merge that same week.",
            external_reference: { system: "slack", url: "https://slack.example/archives/CINC/p123" }
          },
          # Commit, Deliver, Celebrate: Accountability & Execution — L3
          # (withdrawn). Demonstrates the activity feed's strikethrough state
          # without polluting the active-evidence count for this cell.
          {
            binding_index: 2, level_offset: 0, source: "manager", author: manager_person,
            type: "presentation",
            title: "Withdrawn: misattributed work item",
            content: "Initial entry credited the Q4 reliability cleanup to Alex but the work " \
                     "was actually led by another teammate. Withdrawing rather than relinking " \
                     "to keep the audit clean.",
            external_reference: nil,
            withdraw: true,
            withdrawal_reason: "misattributed"
          }
        ]

        evidence_seeds.each_with_index do |seed, i|
          binding = bindings[seed[:binding_index]]
          next unless binding

          cap = binding.capability
          target_level_ordinal = (level.ordinal + seed[:level_offset]).clamp(1, level.ordinal)
          evidence_id = SecureRandom.uuid_v7

          handler.record_evidence(
            report_person.id, framework.framework_id, evidence_id,
            capability_stable_id: cap.stable_id,
            level_ordinal: target_level_ordinal,
            source: seed[:source],
            evidence_type: seed[:type],
            custom_type_label: seed[:custom_type_label],
            title: seed[:title],
            content: seed[:content],
            author_id: seed[:author].id,
            external_reference: seed[:external_reference]
          )

          if seed[:withdraw]
            handler.withdraw_evidence(
              report_person.id, framework.framework_id, evidence_id,
              withdrawn_by_id: seed[:author].id,
              reason: seed[:withdrawal_reason]
            )
            puts "  Evidence (#{seed[:source]}, #{cap.name} L#{target_level_ordinal}): " \
                 "recorded then withdrawn — #{seed[:title] || seed[:type]}"
          else
            puts "  Evidence (#{seed[:source]}, #{cap.name} L#{target_level_ordinal}): " \
                 "#{seed[:title] || seed[:type]}"
          end
        end
      end

      puts "Assessment seed complete."
      puts "  Manager: #{manager_person.name} (#{admin_tu.user.email})"
      puts "  Report:  #{report_person.name} (#{report_email} / password123)"
    end
  end
end
