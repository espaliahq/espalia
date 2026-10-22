# frozen_string_literal: true

require "digest"

# Builds the Stress Test Co tenant (#542): every screen at its limits. Long,
# accented and non-Latin text, a few hundred people, every rating and
# lifecycle state, the empty states, and theme colours that are hard to read
# on. Domain data goes through the command handlers, like the other seeds.
#
# Every step looks for what it would create before creating it, so a second
# run leaves the same data. Every name is fictional.
#
# Development/test data only — the rake task guards the environment.
class StressSeed
  SLUG = "stress-test-co"
  PASSWORD = "password123"
  ADMIN_EMAIL = "admin@#{SLUG}.example.com".freeze
  MEMBER_EMAIL = "member@#{SLUG}.example.com".freeze

  THEME = {
    theme: "custom",
    custom_theme: {
      "brand" => { "light" => "#FACC15", "dark" => "#FDE047" },
      "nav-surface" => { "light" => "#DBFC45", "dark" => "#DBFC45" }
    },
    font_family: "Roboto"
  }.freeze

  # Each at the 24-character limit, the longest a badge has to hold.
  STATE_LABELS = {
    mastering_label: "Consistently exceptional",
    underperforming_label: "Not yet meeting the bar!"
  }.freeze

  FRAMEWORK_NAME = "Stress Test Career Framework: Engineering, Product, Design, Data, " \
                   "Operations and Everything In Between (2026 Edition)"
  EMPTY_FRAMEWORK_NAME = "Untitled framework with no roles yet"

  CLOSED_CYCLE = "FY2025 H2 Performance Review — Closed"
  OPEN_CYCLE = "FY2026 H1 Growth Conversations, Calibration and Promotion Readiness Review " \
               "for Every Team (Including Contractors and Secondments)"
  EMPTY_CYCLE = "Ad-hoc cycle with no participants yet"
  # A framework allows one open cycle, so the empty cycle needs its own.
  SMALL_FRAMEWORK_NAME = "Contractor Framework"

  LEVELS = [
    "Associate", "Intermediate", "Senior", "Staff", "Principal",
    "Distinguished Fellow of the Extraordinarily Long Level Title"
  ].freeze
  LONG_LADDER = %w[Apprentice Associate Intermediate Senior Lead Staff Principal Distinguished Fellow].freeze

  # [family, department, [[role, code, track], …]]
  ROLE_FAMILIES = [
    [ "Platform Reliability, Infrastructure & Developer Experience Engineering", "Engineering", [
      [ "Software Engineer", "SE", "ic" ],
      [ "Principal Distinguished Staff Software Engineer, Payments Platform Infrastructure (Acting)", "PSE", "ic" ],
      [ "Engineering Manager", "EM", "management" ],
      [ "Apprentice-to-Fellow Engineering Ladder", "AFL", "ic" ]
    ] ],
    [ "Product Management", "Product", [
      [ "Product Manager", "PM", "ic" ], [ "Product Owner", "PO", "ic" ], [ "Group Product Manager", "GPM", "management" ]
    ] ],
    [ "Design", "Design", [
      [ "Product Designer", "PD", "ic" ], [ "Content Designer", "CD", "ic" ], [ "Design Manager", "DM", "management" ]
    ] ],
    [ "Données et Analytique", "Data", [
      [ "Analyste de données", "DA", "ic" ], [ "Data Scientist", "DS", "ic" ], [ "Responsable Data", "RD", "management" ]
    ] ],
    [ "研究開発 (Research & Development)", "Research", [
      [ "研究員", "RS", "ic" ], [ "Research Engineer", "RE", "ic" ], [ "研究マネージャー", "RM", "management" ]
    ] ],
    [ "Customer Success, Support, Onboarding and Long-Term Account Health", "Customer", [
      [ "Support Specialist", "SS", "ic" ], [ "Customer Success Manager", "CSM", "ic" ], [ "Head of Support", "HS", "management" ]
    ] ],
    [ "People & Culture", "People", [
      [ "People Partner", "PP", "ic" ], [ "Talent Acquisition Partner", "TA", "ic" ], [ "People Lead", "PL", "management" ]
    ] ],
    [ "Operations", "Operations", [
      [ "Operations Analyst", "OA", "ic" ], [ "Finance Partner", "FP", "ic" ], [ "Operations Manager", "OM", "management" ]
    ] ]
  ].freeze

  # [category, scope, [capability, …]]; scope is :all, :management, or the family indexes bound.
  CATEGORIES = [
    [ "Craft & Technical Excellence", :all, [
      "Code Quality",
      "System Design & Architecture for Large-Scale, Multi-Region, Highly Available Distributed Systems",
      "Testing", "Débogage et résolution de problèmes", "Security", "Observability"
    ] ],
    [ "Collaboration, Communication, Influence and Stakeholder Management Across Distributed Teams", :all, [
      "Communication",
      "Written Communication Including Proposals, RFCs, Post-Incident Reviews and Long-Form Documentation",
      "Feedback", "Stakeholder Management", "Mentoring", "Cross-functional Collaboration"
    ] ],
    [ "Leadership", :management, [
      "Hiring", "People Development", "Strategy", "Org Design", "Performance Management",
      "Leading Through Ambiguity, Organisational Change and Competing Priorities Without Losing the Team"
    ] ],
    [ "Delivery", [ 0, 1, 2, 3 ], [
      "Planning", "Execution", "Estimation", "Risk Management", "Prioritisation", "Release Management"
    ] ],
    [ "Domain Knowledge — 领域知识 — Connaissances métier", [ 4, 5, 6, 7 ], [
      "Customer Empathy", "领域知识与业务理解", "Data Literacy", "Regulatory Compliance", "Market Awareness", "Product Sense"
    ] ],
    [ "Culture", :all, [
      "Ownership", "Inclusion", "Curiosity",
      "Supercalifragilisticexpialidociousoperationalexcellencewithoutasinglespace",
      "Resilience", "Values"
    ] ]
  ].freeze
  REQUIRED_CAPABILITY = "Security"

  NO_SPACES = "Thisisasentencewithnospacesatallsothebrowserhasnowheretobreakitandthelayoutmustcopewithoverflow" \
              "intheassessmentcellsevidencecardsandcommentthreadswithoutpushingthepagesideways"
  LONG_TEXT = "Led the multi-quarter migration of the reservations ledger to the event-sourced platform, " \
              "coordinating six teams across three time zones, writing the decision record, running the " \
              "weekly risk review, pairing with two newer engineers on the trickiest backfill, and keeping " \
              "the customer-facing error rate under the agreed budget the whole way through. " * 4

  FIRST_NAMES = [
    "Zoë", "José", "Søren", "Łukasz", "Ngọc Anh", "Siobhán", "Åsa", "François", "Ingrid", "Kwame",
    "Aroha", "Mateus", "Priya", "Hēmi", "Dmitri", "Yusuf", "Chiamaka", "Bartholomew", "Maximiliana", "Eleanor"
  ].freeze
  LAST_NAMES = [
    "Nguyễn", "O'Sullivan", "García-Márquez", "Müller", "Wolfeschlegelsteinhausenbergerdorff", "Ó Briain",
    "van der Berg-Ashworth", "Kowalczyk", "Takahashi", "Mensah", "Te Rangi", "Fitzgerald-Montgomery",
    "Ålund", "Okonkwo", "Lindqvist", "Papadopoulos", "Haddad", "Ramírez"
  ].freeze
  NON_LATIN_NAMES = [
    "王小明", "佐藤 さくら", "Олена Шевченко", "Παναγιώτης Παπαδόπουλος", "محمد عبد الرحمن",
    "प्रिया शर्मा", "김민준", "Αθηνά Γεωργίου", "יעל כהן", "ณัฐวุฒิ ศรีสุข"
  ].freeze

  CEO_NAME = "Aurelia Montgomery-Fitzwilliam-Worthington"
  MEMBER_NAME = "Maximiliana Wolfeschlegelsteinhausenbergerdorff"
  MEGA_MANAGER_NAME = "Siobhán Ní Bhriain-O'Sullivan"
  LONG_NAME = "José María García-Márquez de la Fuente y Altamirano-Villaseñor"

  # Rated people cycle through these, so every state appears.
  STATES = %i[not_started self_partial self_complete manager_partial both_complete aligning aligned].freeze

  # @param people [Integer] head count; the test passes a small one
  # @param rated [Integer] how many open-cycle participants get ratings
  # @param io [IO] progress sink
  def initialize(people: 300, rated: 42, io: $stdout)
    @people_count = people
    @rated_count = rated
    @io = io
    @framework_handler = Frameworks::CommandHandler.new
    @development = PersonDevelopment::CommandHandler.new
    @cycles = AssessmentCycles::CommandHandler.new
    @calibration = AssessmentCycles::CalibrationCommandHandler.new
  end

  # @return [Tenant]
  def call
    @tenant = upsert_tenant
    ActsAsTenant.with_tenant(@tenant) do
      upsert_people
      upsert_logins
      @framework = upsert_framework
      upsert_empty_framework
      upsert_framework_activity
      assign_people
      seed_closed_cycle
      seed_open_cycle
      seed_member_activity
      seed_calibration_sessions
      seed_empty_cycle
    end
    @tenant
  end

  private

  def upsert_tenant
    tenant = Tenant.find_or_initialize_by(slug: SLUG)
    tenant.assign_attributes(name: "Stress Test Co", **THEME, **STATE_LABELS)
    tenant.save! if tenant.changed?
    tenant
  end

  # ── People ──

  # A CEO, a head per role family, one manager with a huge team, line
  # managers under the heads, and everyone else under a line manager. The
  # last few are contractors with no framework assignment, and leavers.
  def upsert_people
    @plan = []
    add = ->(name, manager:, family:, track:, email: nil) do
      @plan << { name: name, manager: manager, family: family, track: track,
                 email: email || "person-#{format('%03d', @plan.size)}@#{SLUG}.example.com" }
      @plan.size - 1
    end

    ceo = add.(CEO_NAME, manager: nil, family: 0, track: :management, email: ADMIN_EMAIL)
    heads = ROLE_FAMILIES.each_index.map { |f| add.(name_for(@plan.size), manager: ceo, family: f, track: :management) }
    mega = add.(MEGA_MANAGER_NAME, manager: heads[0], family: 0, track: :management)
    line_managers = Array.new([ 16, @people_count / 10 ].min) do |i|
      family = i % ROLE_FAMILIES.size
      add.(name_for(@plan.size), manager: heads[family], family: family, track: :management)
    end

    add.(MEMBER_NAME, manager: mega, family: 0, track: :ic, email: MEMBER_EMAIL)
    add.(LONG_NAME, manager: mega, family: 0, track: :ic)
    mega_size = (@people_count * 0.14).ceil
    (mega_size - 2).times { add.(name_for(@plan.size), manager: mega, family: 0, track: :ic) }

    @unassigned_from = @people_count - 5
    i = 0
    while @plan.size < @people_count
      manager = line_managers[i % line_managers.size]
      add.(name_for(@plan.size), manager: manager, family: @plan[manager][:family], track: :ic)
      i += 1
    end

    @people = []
    @plan.each_with_index do |row, index|
      person = Person.find_or_initialize_by(email: row[:email])
      person.assign_attributes(
        name: row[:name], manager_id: row[:manager] && @people[row[:manager]].id,
        department: ROLE_FAMILIES[row[:family]][1], job_title: job_title_for(row, index),
        status: index >= @people_count - 2 ? "inactive" : "active"
      )
      person.save! if person.changed?
      @people << person
    end

    @ceo = @people[ceo]
    @heads = heads.map { |i| @people[i] }
    @mega = @people[mega]
    @member = Person.find_by!(email: MEMBER_EMAIL)
    @io.puts "People: #{@people.size} (#{@mega.name} has #{mega_size} reports)"
  end

  def name_for(index)
    return NON_LATIN_NAMES[(index / 7) % NON_LATIN_NAMES.size] if (index % 7).zero?

    "#{FIRST_NAMES[index % FIRST_NAMES.size]} #{LAST_NAMES[(index * 7) % LAST_NAMES.size]}"
  end

  def job_title_for(row, index)
    return "Contractor (no framework assignment)" if index >= @unassigned_from

    role = role_spec_for(row, index)
    titles = role[1] == "AFL" ? LONG_LADDER : LEVELS
    "#{titles[level_ordinal_for(row, index, role) - 1]} #{role[0]}"
  end

  def upsert_logins
    [ [ ADMIN_EMAIL, :admin, @ceo ], [ MEMBER_EMAIL, :member, @member ] ].each do |email, role, person|
      user = User.find_or_create_by!(email: email) do |u|
        u.password = PASSWORD
        u.password_confirmation = PASSWORD
      end
      tenant_user = TenantUser.find_or_initialize_by(tenant: @tenant, user: user)
      tenant_user.assign_attributes(role: role, person: person)
      tenant_user.save! if tenant_user.changed?
    end
  end

  # ── Framework ──

  def upsert_framework
    framework = FrameworkState::Framework.find_by(name: FRAMEWORK_NAME)
    build_framework unless framework
    framework = FrameworkState::Framework.find_by!(name: FRAMEWORK_NAME)

    unless framework.draft_in_progress? || framework.current_published_version.to_i > 1
      open_draft(framework)
      framework.reload
    end
    framework
  end

  # The same single unit of work the me&u seed uses: one replay, one append.
  def build_framework
    framework_id = SecureRandom.uuid_v7
    role_ids = {}
    @framework_handler.batch(framework_id) do
      @framework_handler.create_framework(framework_id, FRAMEWORK_NAME)

      ROLE_FAMILIES.each_with_index do |(family, department, roles), family_index|
        family_id = SecureRandom.uuid_v7
        @framework_handler.add_role_family(framework_id, family_id, family,
          description: "#{family} — every role in this family shares the core capabilities.", department: department)
        roles.each do |name, code, track|
          role_id = SecureRandom.uuid_v7
          role_ids[code] = [ role_id, family_index, track ]
          @framework_handler.add_role(framework_id, role_id, family_id, name, code, track)
          titles = code == "AFL" ? LONG_LADDER : LEVELS
          titles.each_with_index do |title, i|
            @framework_handler.add_level(framework_id, SecureRandom.uuid_v7, role_id, i + 1, title, "#{code}#{i + 1}",
              is_entry: i.zero?)
          end
        end
      end

      CATEGORIES.each_with_index do |(category, scope, capabilities), category_index|
        category_id = SecureRandom.uuid_v7
        @framework_handler.add_capability_category(framework_id, category_id, category,
          description: "What #{category.downcase} looks like at every level.", ordinal: category_index + 1)
        bound = role_ids.values.select do |_, family_index, track|
          scope == :all || (scope == :management ? track == "management" : scope.include?(family_index))
        end

        capabilities.each_with_index do |capability, capability_index|
          capability_id = SecureRandom.uuid_v7
          @framework_handler.add_capability(framework_id, capability_id, SecureRandom.uuid_v7, category_id, capability,
            description: capability_index.zero? ? LONG_TEXT : "How someone shows #{capability} in their work.")
          tolerance = capability == REQUIRED_CAPABILITY ? 0 : nil
          bound.each do |role_id, _, _|
            @framework_handler.create_capability_role_binding(framework_id, SecureRandom.uuid_v7, capability_id, role_id,
              individual_tolerance: tolerance)
          end

          LONG_LADDER.size.times do |i|
            expectation_id = SecureRandom.uuid_v7
            @framework_handler.set_behavioural_expectation(framework_id, expectation_id, SecureRandom.uuid_v7,
              capability_id, i + 1, expectation_text(capability, i + 1, capability_index))
            next unless capability_index < 3 && i < LEVELS.size

            illustration_role = role_ids.fetch("SE").first
            [ "Pairs on the gnarliest bug of the sprint and writes up what they learned.", LONG_TEXT ]
              .each_with_index do |text, ordinal|
                @framework_handler.add_role_illustration(framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7,
                  expectation_id, illustration_role, ordinal + 1, text)
              end
          end
        end
      end
    end
    @framework_handler.publish_version(framework_id, "seed")
    @io.puts "Framework published: #{role_ids.size} roles, #{CATEGORIES.sum { |c| c[2].size }} capabilities"
  end

  def expectation_text(capability, level, capability_index)
    return NO_SPACES if capability_index == 5 && level == 3
    return "#{LONG_TEXT} (#{capability}, level #{level})" if capability_index.zero? && level == 4

    "Shows #{capability.downcase} consistently at level #{level}, unprompted, and helps others do the same."
  end

  # A v2 draft with one capability that exists only in the draft.
  def open_draft(framework)
    framework_id = framework.framework_id
    category = FrameworkState::CapabilityCategory.find_by!(framework_id: framework_id, name: CATEGORIES[0][0])
    role = FrameworkState::Role.find_by!(code: "SE")
    @framework_handler.batch(framework_id) do
      @framework_handler.start_draft(framework_id, framework.current_published_version + 1, @ceo.id)
      capability_id = SecureRandom.uuid_v7
      @framework_handler.add_capability(framework_id, capability_id, SecureRandom.uuid_v7, category.category_id,
        "Draft only: AI-Assisted Engineering", description: "Not published yet.")
      @framework_handler.create_capability_role_binding(framework_id, SecureRandom.uuid_v7, capability_id, role.role_id)
      LEVELS.size.times do |i|
        @framework_handler.set_behavioural_expectation(framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7,
          capability_id, i + 1, "Uses AI tools with judgement at level #{i + 1}.")
      end
    end
    @io.puts "Draft v#{framework.current_published_version + 1} opened"
  end

  def upsert_empty_framework
    return if FrameworkState::Framework.exists?(name: EMPTY_FRAMEWORK_NAME)

    @framework_handler.create_framework(SecureRandom.uuid_v7, EMPTY_FRAMEWORK_NAME)
    @io.puts "Empty framework created"
  end

  def seed_empty_cycle
    framework = FrameworkState::Framework.find_by(name: SMALL_FRAMEWORK_NAME)
    unless framework
      framework_id = SecureRandom.uuid_v7
      @framework_handler.batch(framework_id) do
        @framework_handler.create_framework(framework_id, SMALL_FRAMEWORK_NAME)
        family_id, role_id, category_id, capability_id = Array.new(4) { SecureRandom.uuid_v7 }
        @framework_handler.add_role_family(framework_id, family_id, "Contractors", department: "Operations")
        @framework_handler.add_role(framework_id, role_id, family_id, "Contractor", "CON", "ic")
        @framework_handler.add_level(framework_id, SecureRandom.uuid_v7, role_id, 1, "Contractor", "CON1", is_entry: true)
        @framework_handler.add_capability_category(framework_id, category_id, "Delivery", ordinal: 1)
        @framework_handler.add_capability(framework_id, capability_id, SecureRandom.uuid_v7, category_id, "Execution")
        @framework_handler.create_capability_role_binding(framework_id, SecureRandom.uuid_v7, capability_id, role_id)
        @framework_handler.set_behavioural_expectation(framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7,
          capability_id, 1, "Delivers what was agreed.")
      end
      @framework_handler.publish_version(framework_id, "seed")
      framework = FrameworkState::Framework.find_by!(framework_id: framework_id)
    end
    return if AssessmentCycle.for_framework(framework.framework_id).exists?(name: EMPTY_CYCLE)

    @cycles.define_cycle(SecureRandom.uuid_v7, framework.framework_id, EMPTY_CYCLE, "regular",
      framework.current_published_version, defined_by: @ceo.id)
    @io.puts "Cycle defined: #{EMPTY_CYCLE}"
  end

  # Collaborators, and pending suggestions with a long review thread.
  def upsert_framework_activity
    framework_id = @framework.framework_id
    return if FrameworkState::SuggestedEdit.where(framework_id: framework_id).exists?

    # One batch: a single replay and append, so a failure part-way leaves nothing to trip the re-run guard.
    @framework_handler.batch(framework_id) do
      editor, collaborator = @heads[0], @mega
      @framework_handler.add_collaborator(framework_id, @ceo.id, "owner", added_by: @ceo.id)
      @framework_handler.add_collaborator(framework_id, editor.id, "editor", added_by: @ceo.id)
      @framework_handler.add_collaborator(framework_id, collaborator.id, "collaborator", added_by: @ceo.id)

      capabilities = FrameworkState::Capability.joins(:category)
        .where(framework_capability_categories: { framework_id: framework_id }).order(:name).to_a
      capabilities.first(8).each_with_index do |capability, i|
        expectation = FrameworkState::BehaviouralExpectation.find_by!(capability_id: capability.capability_id, level_ordinal: 3)
        value = i.even? ? "#{LONG_TEXT} (suggested rewrite #{i + 1})" : NO_SPACES
        suggestion_id = SecureRandom.uuid_v7
        @framework_handler.suggest_edit(framework_id, suggestion_id, "behavioural_expectation", expectation.expectation_id,
          "description", value, collaborator.id, rationale: "Clearer for people at this level. #{LONG_TEXT if i.zero?}",
          mode: :suggesting)
        next unless i.zero?

        parent = nil
        12.times do |n|
          comment_id = SecureRandom.uuid_v7
          @framework_handler.comment_on_suggestion(framework_id, suggestion_id, comment_id,
            body: "Review note #{n + 1}: #{n.even? ? 'I think this reads better, but check the level above.' : LONG_TEXT}",
            author_id: n.even? ? editor.id : collaborator.id, parent_id: parent)
          parent = comment_id if n < 3
        end
      end

      capability = capabilities.first
      @framework_handler.suggest_edit(framework_id, SecureRandom.uuid_v7, "capability", capability.capability_id,
        "name", "#{capability.name} and Everything Adjacent to It, Renamed for Clarity", collaborator.id,
        rationale: "Broaden the scope", mode: :suggesting)
    end
    @io.puts "Framework suggestions seeded"
  end

  # ── Assignments ──

  def role_spec_for(row, index)
    roles = ROLE_FAMILIES[row[:family]][2]
    return roles.find { |r| r[2] == "management" } if row[:track] == :management

    ics = roles.select { |r| r[2] == "ic" }
    ics[index % ics.size]
  end

  def level_ordinal_for(row, index, role)
    return row[:manager].nil? ? 6 : 5 if row[:track] == :management
    return [ 1, 8, 9 ][index % 3] if role[1] == "AFL"

    (index % 5) + 1
  end

  def assign_people
    assigned = PersonFrameworkAssignment.where(framework_id: @framework.framework_id).pluck(:person_id).to_set
    roles = FrameworkState::Role.all.index_by(&:code)
    levels = FrameworkState::Level.all.index_by { |l| [ l.role_id, l.ordinal ] }
    count = 0
    @plan.each_with_index do |row, index|
      person = @people[index]
      next if index >= @unassigned_from || assigned.include?(person.id)

      spec = role_spec_for(row, index)
      role = roles.fetch(spec[1])
      level = levels.fetch([ role.role_id, level_ordinal_for(row, index, spec) ])
      @development.assign_to_framework(person.id, @framework.framework_id, role.role_id, level.level_id)
      count += 1
    end
    @io.puts "Assigned #{count} people to the framework"
  end

  # ── Cycles ──

  def define_cycle(name, cycle_type)
    cycle = AssessmentCycle.for_framework(@framework.framework_id).find_by(name: name)
    return cycle if cycle

    cycle_id = SecureRandom.uuid_v7
    @cycles.define_cycle(cycle_id, @framework.framework_id, name, cycle_type,
      @framework.current_published_version, defined_by: @ceo.id, planned_end_at: Date.current + 45)
    @io.puts "Cycle defined: #{name}"
    AssessmentCycle.find_by!(cycle_id: cycle_id)
  end

  def enroll(cycle, people)
    enrolled = AssessmentCycleEnrollment.where(cycle_id: cycle.cycle_id).pluck(:person_id).to_set
    assignments = PersonFrameworkAssignment.where(framework_id: @framework.framework_id).index_by(&:person_id)
    people.each do |person|
      assignment = assignments[person.id]
      next if assignment.nil? || enrolled.include?(person.id)

      @cycles.enroll(cycle.cycle_id, person.id, enrolled_by: @ceo.id,
        role_id: assignment.role_id, level_id: assignment.level_id)
    end
  end

  # The mega-manager's team, rated and partly aligned, then closed — so the
  # open cycle opens with their ratings carried forward.
  def seed_closed_cycle
    cycle = AssessmentCycle.for_framework(@framework.framework_id).find_by(name: CLOSED_CYCLE)
    return if cycle&.status == "closed"

    cycle = define_cycle(CLOSED_CYCLE, "performance_review")
    team = @mega.direct_reports.order(:email).to_a
    enroll(cycle, team)
    team.first(@rated_count / 3).each_with_index do |person, i|
      rate(cycle, person, i.even? ? :aligned : :both_complete)
    end
    session_on(cycle, "#{CLOSED_CYCLE} calibration", start: true)
    @cycles.close_cycle(cycle.cycle_id, closed_by: @ceo.id)
    @io.puts "Closed: #{CLOSED_CYCLE}"
  end

  def seed_open_cycle
    @open_cycle = define_cycle(OPEN_CYCLE, "regular")
    enroll(@open_cycle, @people.select { |p| p.status == "active" })

    rated = [ @member ] + @mega.direct_reports.order(:email).where.not(id: @member.id).to_a
    line_managers = Person.where(manager_id: @heads.map(&:id)).where.not(id: @mega.id)
    rated += Person.where(manager_id: line_managers.select(:id)).order(:email).to_a
    rated.uniq.first(@rated_count).each_with_index do |person, i|
      rate(@open_cycle, person, person == @member ? :manager_partial : STATES[i % STATES.size])
      seed_light_evidence(person) if i.odd?
    end
    @io.puts "Rated #{[ rated.size, @rated_count ].min} people in the open cycle"
  end

  # Takes a person to one rating state. Each step checks the read model
  # first, so a re-run fills gaps rather than piling up revisions.
  def rate(cycle, person, state)
    return if state == :not_started

    enrollment = AssessmentCycleEnrollment.find_by(cycle_id: cycle.cycle_id, person_id: person.id)
    return unless enrollment&.role_id

    framework_id = @framework.framework_id
    scope = Assessments::RoleScope.for(role_id: enrollment.role_id, framework_id: framework_id)
    cells = scope.at_level(enrollment.level_ordinal).cells.to_a.sort
    existing = AssessmentLevelRating.across_all_roles.for_person(person.id).for_framework(framework_id)
      .for_cycle(cycle.cycle_id).index_by { |r| [ r.capability_stable_id, r.level_ordinal ] }
    manager_id = person.manager_id
    frequencies = AssessmentLevelRating::FREQUENCIES

    self_cells = %i[self_partial manager_partial].include?(state) ? cells.first(cells.size / 2) : cells
    manager_cells = case state
    when :self_partial, :self_complete then []
    when :manager_partial then cells.first(cells.size / 2)
    else cells
    end
    agree = state == :aligned

    self_cells.each do |key|
      next if existing[key]&.self_rated_frequency && existing[key].self_rating_source == "human"

      @development.rate_self(person.id, framework_id, key[0], level_ordinal: key[1],
        frequency: frequencies[weight("self", person.id, *key)], cycle_id: cycle.cycle_id,
        comment: weight("comment", person.id, *key) < 0.15 ? LONG_TEXT : nil)
    end
    manager_cells.each do |key|
      next if existing[key]&.manager_rated_frequency && existing[key].manager_rating_source == "human"

      value = agree ? weight("self", person.id, *key) : weight("manager", person.id, *key)
      @development.rate_as_manager(person.id, framework_id, key[0], level_ordinal: key[1],
        frequency: frequencies[value], cycle_id: cycle.cycle_id, rated_by_id: manager_id)
    end
    rate_above_level(cycle, person, scope, enrollment, existing) if state == :both_complete

    align(cycle, person, cells, state) if %i[aligning aligned].include?(state)
  end

  # Above-level evidence of a star: consistent at the next level up.
  def rate_above_level(cycle, person, scope, enrollment, existing)
    scope.at_level(enrollment.level_ordinal + 1).cells.to_a.sort.first(4).each do |key|
      next if existing[key]&.manager_rated_frequency

      @development.rate_as_manager(person.id, @framework.framework_id, key[0], level_ordinal: key[1],
        frequency: "consistent", cycle_id: cycle.cycle_id, rated_by_id: person.manager_id)
    end
  end

  def align(cycle, person, cells, state)
    progress = AssessmentCycleProgress.find_by(cycle_id: cycle.cycle_id, person_id: person.id)
    return if progress&.status == "aligned"

    framework_id = @framework.framework_id
    unless progress&.status == "aligning"
      @development.start_alignment(person.id, framework_id, cycle.cycle_id, started_by_id: person.manager_id)
    end
    return unless state == :aligned

    aligned = AssessmentLevelRating.across_all_roles.for_person(person.id).for_framework(framework_id)
      .for_cycle(cycle.cycle_id).where.not(aligned_frequency: nil)
      .pluck(:capability_stable_id, :level_ordinal).to_set
    cells.each do |key|
      next if aligned.include?(key)

      @development.align_assessment(person.id, framework_id, key[0], level_ordinal: key[1],
        aligned_frequency: AssessmentLevelRating::FREQUENCIES[weight("self", person.id, *key)],
        cycle_id: cycle.cycle_id, aligned_by_id: person.manager_id)
    end
    @development.complete_alignment(person.id, framework_id, cycle.cycle_id,
      completed_by_id: person.manager_id, required_cell_keys: cells)
  end

  # Two pieces from the manager, so evidence counts aren't all on one person.
  def seed_light_evidence(person)
    enrollment = AssessmentCycleEnrollment.find_by(cycle_id: @open_cycle.cycle_id, person_id: person.id)
    return unless enrollment&.role_id

    titles = EvidenceItem.for_person(person.id).for_framework(@framework.framework_id).pluck(:title).to_set
    cells = Assessments::RoleScope.for(role_id: enrollment.role_id, framework_id: @framework.framework_id)
      .at_level(enrollment.level_ordinal).cells.to_a.sort
    [ "Ran the incident review", "Mentored a new starter through their first release" ].each_with_index do |title, i|
      next if titles.include?(title) || cells[i].nil?

      @development.record_evidence(person.id, @framework.framework_id, SecureRandom.uuid_v7,
        source: "manager", evidence_type: "observation", title: title, content: "Seen first hand this quarter.",
        author_id: person.manager_id, capability_stable_id: cells[i][0], level_ordinal: cells[i][1],
        valence: i.zero? ? "demonstrated" : "growth_area")
    end
  end

  # ── The member's assessment: evidence, a long thread, requests ──

  def seed_member_activity
    framework_id = @framework.framework_id
    enrollment = AssessmentCycleEnrollment.find_by!(cycle_id: @open_cycle.cycle_id, person_id: @member.id)
    cells = Assessments::RoleScope.for(role_id: enrollment.role_id, framework_id: framework_id)
      .at_level(enrollment.level_ordinal).cells.to_a.sort
    peer = @mega.direct_reports.where.not(id: @member.id).order(:email).first
    seed_evidence(cells, peer)
    seed_thread(cells.first)
    seed_requests(cells, peer)
  end

  def seed_evidence(cells, peer)
    titles = EvidenceItem.for_person(@member.id).for_framework(@framework.framework_id).pluck(:title).to_set
    valences = EvidenceLink::VALENCES
    authors = { "self" => @member, "manager" => @mega, "peer" => peer }

    36.times do |i|
      title = case i
      when 0 then "Evidence #{i + 1}: #{NO_SPACES}"
      when 1 then "Evidence #{i + 1}: #{LONG_TEXT.first(240)}"
      else "Evidence #{i + 1}: shipped the quarterly reliability work"
      end
      next if titles.include?(title)

      key = cells[i % cells.size]
      source = authors.keys[i % 3]
      evidence_id = SecureRandom.uuid_v7
      cell = i == 35 ? {} : { capability_stable_id: key[0], level_ordinal: key[1], valence: valences[i % valences.size] }
      evidence_type = EvidenceItem::EVIDENCE_TYPES[i % EvidenceItem::EVIDENCE_TYPES.size]
      @development.record_evidence(@member.id, @framework.framework_id, evidence_id,
        source: source, evidence_type: evidence_type,
        custom_type_label: evidence_type == "other" ? "Keynote at an international conference, recorded" : nil,
        title: title, content: i.even? ? LONG_TEXT : "Short and to the point.",
        author_id: authors[source].id,
        external_reference: i % 4 == 0 ? { system: "github", url: "https://github.com/example/repo/pull/#{1000 + i}" } : nil,
        **cell)
      next unless i == 7 || i == 8

      @development.withdraw_evidence(@member.id, @framework.framework_id, evidence_id,
        withdrawn_by_id: authors[source].id, reason: "misattributed")
    end
  end

  def seed_thread(cell)
    bodies = PersonDevelopmentComment.for_person(@member.id).for_framework(@framework.framework_id).pluck(:body).to_set
    parent = nil
    30.times do |n|
      body = "##{n + 1} #{[ 'Agreed.', LONG_TEXT, NO_SPACES, 'Can we talk about this in our next 1:1? 🙏' ][n % 4]}"
      existing = PersonDevelopmentComment.for_person(@member.id).find_by(body: body) if bodies.include?(body)
      if existing
        parent = existing.id if n < 5
        next
      end

      comment_id = SecureRandom.uuid_v7
      @development.post_comment(@member.id, @framework.framework_id, comment_id,
        commentable_type: PersonDevelopmentComment::ASSESSMENT_CELL,
        capability_stable_id: cell[0], level_ordinal: cell[1], body: body,
        author_id: n.even? ? @member.id : @mega.id, parent_id: n.between?(1, 5) ? parent : nil)
      parent = comment_id if n < 5
    end
  end

  def seed_requests(cells, peer)
    framework_id = @framework.framework_id
    messages = EvidenceRequest.for_assessment(@member.id, framework_id).pluck(:message).to_set
    [
      [ @member, @mega, :pending, "Could you share what you saw during the outage? #{LONG_TEXT}" ],
      [ @member, peer, :responded, "Would you share feedback on the migration pairing?" ],
      [ @member, peer, :declined, "Could you add anything on the design review?" ],
      [ @mega, peer, :cancelled, NO_SPACES ]
    ].each_with_index do |(requested_by, requestee, outcome, message), i|
      next if messages.include?(message)

      key = cells[i]
      request_id = SecureRandom.uuid_v7
      @development.request_evidence(@member.id, framework_id, request_id,
        requested_by_id: requested_by.id, requestee_person_id: requestee.id,
        capability_stable_id: key[0], level_ordinal: key[1], message: message)
      case outcome
      when :responded
        @development.record_evidence_for_request(@member.id, framework_id, request_id, SecureRandom.uuid_v7,
          responded_by_id: requestee.id, source: "peer", evidence_type: "peer_feedback",
          content: LONG_TEXT, author_id: requestee.id, capability_stable_id: key[0],
          level_ordinal: key[1], valence: "demonstrated")
      when :declined
        @development.decline_evidence_request(@member.id, framework_id, request_id,
          declined_by_id: requestee.id, reason: "Wasn't close enough to the work to say.")
      when :cancelled
        @development.cancel_evidence_request(@member.id, framework_id, request_id, cancelled_by_id: requested_by.id)
      end
    end
  end

  # ── Calibration ──

  # One session in each stage on the open cycle.
  def seed_calibration_sessions
    base = "Engineering calibration"
    session_on(@open_cycle, "#{base} (draft)", start: false)
    session_on(@open_cycle, "#{base} — live, with a very long session name to see where it wraps", start: true) do |id, calibrants|
      3.times do |n|
        @calibration.record_note(id, body: n.zero? ? LONG_TEXT : "Note #{n + 1}: #{NO_SPACES}",
          person_id: n == 2 ? calibrants.first : nil, recorded_by_id: @heads[0].id)
      end
    end
    session_on(@open_cycle, "#{base} (closed)", start: true) do |id, _|
      @calibration.close_session(id, closed_by_id: @heads[0].id)
    end
    session_on(@open_cycle, "#{base} (archived)", start: true) do |id, _|
      @calibration.close_session(id, closed_by_id: @heads[0].id)
      @calibration.archive_session(id, archived_by_id: @heads[0].id)
    end
  end

  # The engineering head facilitates; the managers under them rate; their
  # enrolled reports are calibrated.
  def session_on(cycle, name, start:)
    return if CalibrationSession.exists?(cycle_id: cycle.cycle_id, name: name)

    facilitator = @heads[0]
    enrolled = AssessmentCycleEnrollment.active.where(cycle_id: cycle.cycle_id).pluck(:person_id).to_set
    raters = Person.where(manager_id: facilitator.id).order(:email)
      .select { |rater| rater.direct_reports.any? { |p| enrolled.include?(p.id) } }
    calibrants = Person.where(manager_id: raters.map(&:id), id: enrolled.to_a).order(:email).pluck(:id)
    return @io.puts("  No raters for '#{name}' — skipped") if raters.empty? || calibrants.empty?

    session_id = SecureRandom.uuid_v7
    @calibration.define_session(session_id, cycle.cycle_id, @framework.framework_id, name,
      @framework.current_published_version, facilitator_id: facilitator.id,
      participant_ids: raters.map(&:id), calibrant_person_ids: calibrants, defined_by: facilitator.id)
    @calibration.start_session(session_id, started_by_id: facilitator.id) if start
    yield session_id, calibrants if block_given?
    @io.puts "Calibration session: #{name}"
  end

  # Deterministic index into the four frequencies, so re-runs agree.
  def weight(*parts)
    Digest::SHA256.hexdigest([ "stress-v1", *parts ].join("/"))[0, 8].to_i(16) % 4
  end
end
