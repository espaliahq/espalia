# frozen_string_literal: true

# The Null Island Systems demo tenant db/seeds.rb builds outside production:
# ten people on @nullisland.example, the example framework (loaded from YAML
# by frameworks:seed), an open cycle with ratings in every state a dashboard
# distinguishes, evidence, pending suggestions and an open v2 draft. Every
# step is idempotent, so re-seeding converges instead of duplicating.
#
# StressSeed is the volume fixture (hundreds of people, every edge state);
# this is the demo fixture — small enough to read on one screen in the app.
class ExampleSeed
  # The demo tenant brands its instance "Ladder" to show the product name is
  # a tenant setting; Driftwood keeps the instance default for contrast.
  TENANT = { slug: "nullisland", name: "Null Island Systems", product_name: "Ladder" }.freeze
  # A second workspace so the tenant switcher has somewhere to switch to.
  SECOND_TENANT = { slug: "driftwood", name: "Driftwood Labs" }.freeze
  CYCLE_NAME = "Q4 2026 Capability Review"
  PASSWORD = "password123"

  # key => [name, job title, department, manager key, role code, level ordinal, login?]
  PEOPLE = {
    "imogen"  => [ "Imogen Tidewell", "VP Product & Engineering", "Product & Engineering", nil, nil, nil, false ],
    "marisol" => [ "Marisol Vega", "Engineering Manager", "Engineering", "imogen", "EM", 3, true ],
    "beatrix" => [ "Beatrix Okafor", "Staff Engineer", "Engineering", "marisol", "E", 4, false ],
    "june"    => [ "June Park", "Senior Engineer", "Engineering", "marisol", "E", 3, false ],
    "theo"    => [ "Theo Okonkwo", "Engineer II", "Engineering", "marisol", "E", 2, true ],
    "anders"  => [ "Anders Lindqvist", "Engineer I", "Engineering", "marisol", "E", 1, false ],
    "falak"   => [ "Falak Noor", "Senior Product Manager", "Product", "imogen", "PM", 3, false ],
    "rafael"  => [ "Rafael Ibarra", "Product Manager", "Product", "falak", "PM", 2, false ],
    "sana"    => [ "Sana Haddad", "Senior Designer", "Product", "falak", "PD", 3, false ],
    "colm"    => [ "Colm Byrne", "Designer I", "Product", "falak", "PD", 1, false ]
  }.freeze

  # person key => rating state (see #rate)
  RATING_STATES = {
    "june" => :aligned, "theo" => :both_complete, "beatrix" => :manager_partial,
    "anders" => :self_partial, "rafael" => :both_complete, "sana" => :self_complete,
    "marisol" => :self_partial
  }.freeze

  def initialize(admin_user:, io: $stdout)
    @admin_user = admin_user
    @io = io
    @frameworks = Frameworks::CommandHandler.new
    @development = PersonDevelopment::CommandHandler.new
    @cycles = AssessmentCycles::CommandHandler.new
  end

  def call
    raise "ExampleSeed is for development and test only." if Rails.env.production?

    tenant = upsert_tenants
    ActsAsTenant.with_tenant(tenant) do
      # Explicit args pin the demo to its own file and tenant — a stray
      # SEED_TENANT_SLUG / SEED_FRAMEWORK_FILE export must not redirect it.
      Rake::Task["frameworks:seed"].execute(
        Rake::TaskArguments.new(%i[file slug], [ "db/seeds/null_island_framework.yml", TENANT[:slug] ])
      )
      @framework = FrameworkState::Framework.first or raise "frameworks:seed left no framework"
      upsert_people
      upsert_logins(tenant)
      assign_people
      upsert_collaborators
      @cycle = define_cycle
      enroll_everyone
      seed_ratings
      seed_evidence
      seed_suggestions
      open_draft
    end
    @io.puts "Null Island Systems ready: sign in as #{SeedAdmin::DEV_EMAIL}, " \
             "#{person('theo').email} or #{person('marisol').email} (#{PASSWORD})"
    tenant
  end

  private

  def upsert_tenants
    tenant = Tenant.find_or_create_by!(slug: TENANT[:slug]) do |t|
      t.name = TENANT[:name]
      t.product_name = TENANT[:product_name]
    end
    second = Tenant.find_or_create_by!(slug: SECOND_TENANT[:slug]) { |t| t.name = SECOND_TENANT[:name] }
    [ tenant, second ].each do |t|
      ActsAsTenant.with_tenant(t) do
        TenantUser.find_or_create_by!(tenant: t, user: @admin_user) { |tu| tu.role = :admin }
      end
    end
    tenant
  end

  def upsert_people
    @people = {}
    PEOPLE.each do |key, (name, title, department, manager_key, _role, _ordinal, _login)|
      person = Person.find_or_initialize_by(email: "#{key}@nullisland.example")
      person.assign_attributes(name: name, job_title: title, department: department,
        manager_id: manager_key && @people.fetch(manager_key).id, status: "active")
      person.save!
      @people[key] = person
    end
  end

  def person(key) = @people.fetch(key)

  def upsert_logins(tenant)
    PEOPLE.each do |key, (_name, _title, _dept, _mgr, _role, _ordinal, login)|
      next unless login

      user = User.find_or_create_by!(email: person(key).email) do |u|
        u.password = PASSWORD
        u.password_confirmation = PASSWORD
      end
      TenantUser.find_or_create_by!(tenant: tenant, user: user) do |tu|
        tu.role = :member
        tu.person = person(key)
      end
    end
  end

  def assign_people
    assigned = PersonFrameworkAssignment.where(framework_id: @framework.framework_id).pluck(:person_id).to_set
    roles = FrameworkState::Role.all.index_by(&:code)
    levels = FrameworkState::Level.all.index_by { |l| [ l.role_id, l.ordinal ] }
    PEOPLE.each do |key, (_name, _title, _dept, manager_key, role_code, ordinal, _login)|
      next if role_code.nil? || assigned.include?(person(key).id)

      role = roles.fetch(role_code)
      level = levels.fetch([ role.role_id, ordinal ])
      @development.assign_to_framework(person(key).id, @framework.framework_id, role.role_id, level.level_id)
      if manager_key
        @development.record_reporting_manager(person(key).id, @framework.framework_id,
          person(manager_key).id, source: "backfill")
      end
    end
  end

  def upsert_collaborators
    existing = FrameworkState::Collaborator.where(framework_id: @framework.framework_id).pluck(:person_id).to_set
    { "marisol" => "owner", "falak" => "editor", "sana" => "collaborator" }.each do |key, role|
      next if existing.include?(person(key).id)

      @frameworks.add_collaborator(@framework.framework_id, person(key).id, role, added_by: person("imogen").id)
    end
  end

  def define_cycle
    cycle = AssessmentCycle.for_framework(@framework.framework_id).find_by(name: CYCLE_NAME)
    return cycle if cycle

    cycle_id = SecureRandom.uuid_v7
    @cycles.define_cycle(cycle_id, @framework.framework_id, CYCLE_NAME, "regular",
      @framework.current_published_version, defined_by: person("imogen").id, planned_end_at: Date.current + 42)
    AssessmentCycle.find_by!(cycle_id: cycle_id)
  end

  def enroll_everyone
    enrolled = AssessmentCycleEnrollment.where(cycle_id: @cycle.cycle_id).pluck(:person_id).to_set
    assignments = PersonFrameworkAssignment.where(framework_id: @framework.framework_id).index_by(&:person_id)
    @people.each_value do |person|
      assignment = assignments[person.id]
      next if assignment.nil? || enrolled.include?(person.id)

      @cycles.enroll(@cycle.cycle_id, person.id, enrolled_by: person.manager_id,
        role_id: assignment.role_id, level_id: assignment.level_id)
    end
  end

  def seed_ratings
    RATING_STATES.each { |key, state| rate(person(key), state) }
  end

  # Takes a person to one rating state, checking the read model first so a
  # re-run fills gaps rather than piling up revisions. (The shape mirrors
  # StressSeed#rate, deliberately — same commands, same idempotency.)
  def rate(person, state)
    enrollment = AssessmentCycleEnrollment.find_by(cycle_id: @cycle.cycle_id, person_id: person.id)
    return unless enrollment&.role_id

    framework_id = @framework.framework_id
    cells = Assessments::RoleScope.for(role_id: enrollment.role_id, framework_id: framework_id)
      .at_level(enrollment.level_ordinal).cells.to_a.sort
    existing = AssessmentLevelRating.across_all_roles.for_person(person.id).for_framework(framework_id)
      .for_cycle(@cycle.cycle_id).index_by { |r| [ r.capability_stable_id, r.level_ordinal ] }
    frequencies = AssessmentLevelRating::FREQUENCIES

    self_cells = %i[self_partial manager_partial].include?(state) ? cells.first(cells.size / 2) : cells
    manager_cells = case state
    when :self_partial, :self_complete then []
    when :manager_partial then cells.first(cells.size / 2)
    else cells
    end

    self_cells.each_with_index do |key, i|
      next if existing[key]&.self_rated_frequency

      @development.rate_self(person.id, framework_id, key[0], level_ordinal: key[1],
        frequency: frequencies[(i + person.id.bytes.last) % frequencies.size], cycle_id: @cycle.cycle_id)
    end
    manager_cells.each_with_index do |key, i|
      next if existing[key]&.manager_rated_frequency

      frequency = state == :aligned ? frequencies[(i + person.id.bytes.last) % frequencies.size]
                                    : frequencies[(i + 1) % frequencies.size]
      @development.rate_as_manager(person.id, framework_id, key[0], level_ordinal: key[1],
        frequency: frequency, cycle_id: @cycle.cycle_id, rated_by_id: person.manager_id)
    end

    align(person, cells) if state == :aligned
  end

  def align(person, cells)
    progress = AssessmentCycleProgress.find_by(cycle_id: @cycle.cycle_id, person_id: person.id)
    return if progress&.status == "aligned"

    framework_id = @framework.framework_id
    unless progress&.status == "aligning"
      @development.start_alignment(person.id, framework_id, @cycle.cycle_id, started_by_id: person.manager_id)
    end
    aligned = AssessmentLevelRating.across_all_roles.for_person(person.id).for_framework(framework_id)
      .for_cycle(@cycle.cycle_id).where.not(aligned_frequency: nil)
      .pluck(:capability_stable_id, :level_ordinal).to_set
    cells.each do |key|
      next if aligned.include?(key)

      @development.align_assessment(person.id, framework_id, key[0], level_ordinal: key[1],
        aligned_frequency: "consistent", cycle_id: @cycle.cycle_id, aligned_by_id: person.manager_id)
    end
    @development.complete_alignment(person.id, framework_id, @cycle.cycle_id,
      completed_by_id: person.manager_id, required_cell_keys: cells)
  end

  # Theo's assessment carries the evidence story: placed, unplaced, withdrawn,
  # and both sides of a request.
  def seed_evidence
    framework_id = @framework.framework_id
    theo = person("theo")
    enrollment = AssessmentCycleEnrollment.find_by!(cycle_id: @cycle.cycle_id, person_id: theo.id)
    cells = Assessments::RoleScope.for(role_id: enrollment.role_id, framework_id: framework_id)
      .at_level(enrollment.level_ordinal).cells.to_a.sort
    titles = EvidenceItem.for_person(theo.id).for_framework(framework_id).pluck(:title).to_set

    [
      [ "Shipped the tile cache eviction fix", "self", "project_outcome", "marisol", "demonstrated", 0,
        "Found the leak under zoom-level churn, added load-shaped tests, and the p99 dropped 40ms." ],
      [ "Geocoder fallback incident writeup", "manager", "incident_response", "marisol", "demonstrated", 1,
        "Theo ran the sev-2 end to end: calm triage, clear comms every 30 minutes, and a review that produced two platform fixes." ],
      [ "Code review on the route planner refactor", "peer", "code_review", "june", "growth_area", 2,
        "Solid catch on the waypoint ordering bug, but the review landed three days after the PR opened — the team was blocked meanwhile." ],
      [ "Paired Anders through his first release", "peer", "mentoring", "beatrix", "demonstrated", 3,
        "Watched Theo pair Anders through the release checklist without taking the keyboard once." ],
      [ "Demo day talk on vector tiles", "self", "presentation", "marisol", "demonstrated", 4,
        "Fifteen minutes on why vector tiles halve our bandwidth, pitched so the support team followed it too." ],
      [ "Buoy status page postmortem notes", "manager", "observation", "marisol", nil, nil,
        "Raw notes from the buoy outage — worth placing once we agree which capability it speaks to." ]
    ].each do |title, source, type, author_key, valence, cell_index, content|
      next if titles.include?(title)

      author = source == "self" ? theo : person(author_key)
      cell = cell_index && cells[cell_index % cells.size]
      placement = cell ? { capability_stable_id: cell[0], level_ordinal: cell[1], valence: valence } : {}
      @development.record_evidence(theo.id, framework_id, SecureRandom.uuid_v7,
        source: source, evidence_type: type == "observation" ? "other" : type,
        custom_type_label: type == "observation" ? "Observation" : nil,
        title: title, content: content,
        author_id: author.id, cycle_id: @cycle.cycle_id, **placement)
    end

    withdrawn_title = "Mistaken attribution — belongs to June"
    unless titles.include?(withdrawn_title)
      withdrawn_id = SecureRandom.uuid_v7
      cell = cells.first
      @development.record_evidence(theo.id, framework_id, withdrawn_id,
        source: "manager", evidence_type: "project_outcome", title: withdrawn_title,
        content: "Logged against the wrong engineer.", author_id: person("marisol").id,
        cycle_id: @cycle.cycle_id, capability_stable_id: cell[0], level_ordinal: cell[1], valence: "demonstrated")
      @development.withdraw_evidence(theo.id, framework_id, withdrawn_id,
        withdrawn_by_id: person("marisol").id, reason: "misattributed")
    end

    seed_requests(theo, cells)
  end

  def seed_requests(theo, cells)
    framework_id = @framework.framework_id
    messages = EvidenceRequest.for_assessment(theo.id, framework_id).pluck(:message).to_set
    pending_message = "Could you share what you saw during the geocoder incident?"
    unless messages.include?(pending_message)
      @development.request_evidence(theo.id, framework_id, SecureRandom.uuid_v7,
        requested_by_id: person("marisol").id, requestee_person_id: person("june").id,
        capability_stable_id: cells[1][0], level_ordinal: cells[1][1], message: pending_message)
    end

    responded_message = "Anything you can add on the vector tile pairing?"
    return if messages.include?(responded_message)

    request_id = SecureRandom.uuid_v7
    @development.request_evidence(theo.id, framework_id, request_id,
      requested_by_id: person("marisol").id, requestee_person_id: person("beatrix").id,
      capability_stable_id: cells[2][0], level_ordinal: cells[2][1], message: responded_message)
    @development.record_evidence_for_request(theo.id, framework_id, request_id, SecureRandom.uuid_v7,
      responded_by_id: person("beatrix").id, source: "peer", evidence_type: "peer_feedback",
      content: "Theo drove the pairing — I mostly navigated.", author_id: person("beatrix").id,
      capability_stable_id: cells[2][0], level_ordinal: cells[2][1], valence: "demonstrated")
  end

  # Pending suggestions, one per review tier, kept pending by mode: :suggesting.
  def seed_suggestions
    framework_id = @framework.framework_id
    return if FrameworkState::SuggestedEdit.where(framework_id: framework_id).any?

    # These names couple to db/seeds/null_island_framework.yml — a rename
    # there must land here too, and the bang finders say which name broke.
    illustration = FrameworkState::RoleIllustration.first!
    capability = FrameworkState::Capability.find_by!(name: "Customer Insight")
    expectation = FrameworkState::BehaviouralExpectation.joins(:capability)
      .find_by!(framework_capabilities: { name: "Shipping & Iteration" }, level_ordinal: 2)

    @frameworks.suggest_edit(framework_id, SecureRandom.uuid_v7, "role_illustration", illustration.illustration_id,
      "description", "#{illustration.description} Names the follow-up owner, too.",
      person("sana").id, rationale: "The follow-up is the part people skip.", mode: :suggesting)
    @frameworks.suggest_edit(framework_id, SecureRandom.uuid_v7, "capability", capability.capability_id,
      "description", "Knows who navigates by the platform and why, and lets real journeys reshape plans.",
      person("rafael").id, rationale: "Journeys reads better than usage for a maps company.", mode: :suggesting)
    @frameworks.suggest_edit(framework_id, SecureRandom.uuid_v7, "behavioural_expectation", expectation.expectation_id,
      "description", "Scopes own work to ship value early, and says out loud when a slice stops earning its place.",
      person("falak").id, rationale: "Killing a slice is the harder half of slicing.", mode: :suggesting)
    designer = FrameworkState::Role.find_by!(code: "PD")
    @frameworks.suggest_create(framework_id, SecureRandom.uuid_v7, "role_illustration",
      { role_id: designer.role_id,
        description: "Walks the support queue weekly and files the top recurring confusion as a design issue." },
      parent_id: expectation.expectation_id, author_id: person("sana").id,
      rationale: "PD needs an illustration at this level.", mode: :suggesting)
  end

  # An open v2 draft so the explorer shows versioning in flight.
  def open_draft
    return if FrameworkState::Framework.find_by(framework_id: @framework.framework_id)&.draft_in_progress

    framework_id = @framework.framework_id
    crew = FrameworkState::CapabilityCategory.find_by!(name: "Crew")
    @frameworks.start_draft(framework_id, @framework.current_published_version + 1, person("marisol").id)
    cap_id = SecureRandom.uuid_v7
    @frameworks.add_capability(framework_id, cap_id, SecureRandom.uuid_v7, crew.category_id,
      "Incident Response", description: "Runs towards the pager — calm triage, honest comms, blameless follow-through.")
    @frameworks.set_behavioural_expectation(framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7,
      cap_id, 2, "Runs a sev-2 end to end: triage, comms cadence, and the review that follows.")
    engineer = FrameworkState::Role.find_by!(code: "E")
    @frameworks.create_capability_role_binding(framework_id, SecureRandom.uuid_v7, cap_id, engineer.role_id)
  end
end
