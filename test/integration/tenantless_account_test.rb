# frozen_string_literal: true

require "test_helper"
require "rake"
require_relative "../../lib/tasks/example_seed"

# A signed-in account that belongs to no tenant runs every request with no
# current tenant, where acts_as_tenant scopes nothing. These tests walk every
# route with ids of seeded records and check that such an account reads none
# of their data and changes nothing.
class TenantlessAccountTest < ActionDispatch::IntegrationTest
  include McpRequestCredentialsHelpers
  include ActionMailer::TestHelper

  # Every other route is crawled. Each entry must match a route and say why it isn't crawled.
  EXEMPT = {
    %r{\A/rails/active_storage/} => "signed blob URLs: the signature grants access, not the session",
    %r{\A/rails/action_mailbox/} => "inbound email webhooks, authenticated by the ingress password",
    %r{\A/rails/conductor/} => "Action Mailbox's conductor refuses every request but a local one",
    %r{\A/users/auth/} => "OmniAuth's middleware answers before any controller runs",
    %r{\A/t/:tenant_slug/sign-in\z} => "the public sign-in page, branded with its tenant's name by design"
  }.freeze

  # Writes that may answer other than with a refusal. Each says why.
  NOT_REFUSED = {
    "/oauth/authorize" => "Doorkeeper refuses a request with no client before it reads the session",
    "/oauth/token" => "Doorkeeper's token endpoint authenticates the client, not the session",
    "/oauth/introspect" => "Doorkeeper's introspection endpoint authenticates the client, not the session",
    "/oauth/register" => "dynamic client registration is open by design and holds no tenant data",
    "/settings/color_scheme" => "the account's own colour scheme, held on the account rather than a tenant",
    "/settings/notifications" => "the account's own notification settings, held on the account rather than a tenant",
    "/notifications/read_all" => "marks read only the account's own notifications",
    "/impersonation" => "refused unless the account is a global admin, before it reads a tenant"
  }.freeze

  # Where a refusal redirects. A redirect anywhere else may be a write that worked. A tenant
  # switch lands on / either way and changes only the session, so its own test below checks it.
  REFUSAL_PATHS = %w[/ /users/sign_in].freeze

  # Writes refused by their own lookup, which return to their own page. Each says where and why.
  # A write that worked lands there too, so the table checksum is what tells the two apart.
  NO_PERSON = "needs a person linked to the account, and returns to the assessments list without one"
  REFUSED_ELSEWHERE = {
    "/settings/connected_clients/:id" => [ %r{\A/settings/connected_clients\z}, "finds the token among the account's own, and returns to the list when none matches" ],
    "/assessments/:assessment_id/carried_ratings" => [ %r{\A/assessments\z}, NO_PERSON ],
    "/assessments/:assessment_id/explorations" => [ %r{\A/assessments\z}, NO_PERSON ],
    "/assessments/:assessment_id/explorations/:exploration_id/closure" => [ %r{\A/assessments\z}, NO_PERSON ],
    "/frameworks/:framework_id/suggestions/:suggestion_id/comments/:id" =>
      [ %r{\A/frameworks/[^/]+/activity\z}, "finds no comment, as none is seeded, and returns to the framework's activity" ]
  }.freeze

  # Bodies for writes that read their params before they authorise, so an empty
  # body would stop them before the check this crawl tests.
  BODIES = {
    "/frameworks/:framework_id/capability_archives" => { archive: { capability_id: "frameworks/capabilities/:id" } },
    "/frameworks/:framework_id/category_archives" => { archive: { category_id: "frameworks/categories/:id" } },
    "/frameworks/:framework_id/illustration_archives" => { archive: { illustration_id: "frameworks/illustrations/:id" } }
  }.freeze

  # The two demo tenants. Every route is crawled once in each, with that tenant's own ids.
  TENANTS = [ ExampleSeed::TENANT[:slug], ExampleSeed::SECOND_TENANT[:slug] ].freeze

  # Where each route segment's id comes from: the table, the column the route reads (or an
  # expression building a composite id), and any condition a usable row meets. A symbol names
  # an id the setup records, for rows that live only in a plan's stream.
  COLLABORATOR = "concat(%s, ':', role, ':', scope_type, ':', scope_id)"
  SOURCES = {
    ":assessment_cycle_id" => %w[assessment_cycles id], ":assessment_id" => %w[person_framework_assignments id],
    ":assignment_id" => %w[person_framework_assignments id], ":budget_line_id" => %w[budget_lines id],
    ":calibration_session_id" => %w[calibration_sessions id], ":capability_id" => %w[framework_capabilities capability_id],
    ":evidence_id" => %w[evidence_items id], ":evidence_item_id" => %w[evidence_items id],
    ":framework_id" => %w[framework_states framework_id], ":level_id" => %w[org_taxonomy_levels id],
    ":org_person_id" => [ "people", "id", "id IN (SELECT person_id FROM org_memberships)" ],
    ":org_unit_id" => [ "org_units", "id", "id IN (SELECT unit_id FROM org_memberships) AND id IN (SELECT unit_id FROM org_unit_owners)" ], ":person_id" => %w[people id],
    ":plan_id" => %w[team_planning_plans id], ":scenario_id" => [ "team_planning_scenarios", "id", "parent_id IS NOT NULL" ],
    ":suggestion_id" => %w[framework_suggested_edits suggestion_id], ":user_id" => [ "tenant_users", "id", "person_id IS NOT NULL" ],
    "applications/:id" => %w[oauth_applications id], "approvals/:id" => %w[mcp_pending_approvals id],
    "assessment_cycles/:id" => %w[assessment_cycles id], "assessment_cycles/enrollments/:id" => %w[assessment_cycle_enrollments id],
    "assessments/:id" => %w[person_framework_assignments id], "assessments/comments/:id" => %w[person_development_comments id],
    "assessments/delegations/:id" => %w[manager_assessment_delegations id], "assessments/evidence/:id" => %w[evidence_items id],
    "budget_lines/:id" => %w[budget_lines id], "calibration_sessions/:id" => %w[calibration_sessions id],
    "calibration_sessions/calibrants/:id" => [ "calibration_session_members", "person_id", "member_type = 'calibrant'" ],
    "calibration_sessions/capabilities/:id" => %w[framework_capabilities capability_id],
    "calibration_sessions/participants/:id" => [ "calibration_session_members", "person_id", "member_type = 'participant'" ],
    "comments/:id" => %w[person_development_comments id], "connected_clients/:id" => %w[oauth_access_tokens id],
    "cost_centre_rules/:id" => :cost_centre_place, "evidence_items/:id" => %w[evidence_items id],
    "evidence_placement_suggestions/:id" => %w[evidence_placement_suggestions id], "evidence_requests/:id" => %w[evidence_requests id],
    "exchange_rates/:id" => %w[exchange_rates id], "frameworks/:id" => %w[framework_states framework_id],
    "frameworks/capabilities/:id" => %w[framework_capabilities capability_id],
    "frameworks/capability_bindings/:id" => %w[framework_capability_role_bindings binding_id],
    "frameworks/categories/:id" => %w[framework_capability_categories category_id],
    "frameworks/collaborators/:id" => [ "framework_collaborators", format(COLLABORATOR, "person_id") ],
    "frameworks/expectations/:id" => %w[framework_behavioural_expectations expectation_id],
    "frameworks/illustrations/:id" => %w[framework_role_illustrations illustration_id], "frameworks/levels/:id" => %w[framework_levels level_id],
    "frameworks/role_families/:id" => %w[framework_role_families role_family_id], "frameworks/roles/:id" => %w[framework_roles role_id],
    "frameworks/suggestions/:id" => %w[framework_suggested_edits suggestion_id], "items/:id" => %w[evidence_items id],
    "levels/:id" => %w[org_taxonomy_levels id], "pay_bands/:id" => %w[pay_bands id], "people/:id" => %w[people id],
    "people/memberships/:id" => %w[org_memberships unit_id], "planning/:id" => %w[team_planning_plans id],
    "planning/assignments/:id" => :placed_person, "planning/fundings/:id" => :position,
    "planning/notes/:id" => %w[team_planning_history_entries id], "planning/positions/:id" => :position,
    "planning/scenarios/:id" => %w[team_planning_scenarios id], "planning/see_pay/:id" => %w[team_planning_plan_members person_id],
    "requests/:id" => %w[evidence_requests id], "units/:id" => %w[org_units id],
    "units/members/:id" => %w[org_memberships person_id], "units/owners/:id" => %w[org_unit_owners person_id],
    "users/:id" => [ "tenant_users", "id", "person_id IS NOT NULL" ],
    "users/collaborators/:id" => [ "framework_collaborators", format(COLLABORATOR, "framework_id") ]
  }.freeze

  # Source tables no tenant owns, so both tenants' crawls draw the same row. Each says why.
  GLOBAL_TABLES = { "oauth_applications" => "an MCP client registers once and is offered to every tenant" }.freeze

  # Parents whose children link to them other than by `<parent>_id`, as child column => parent column.
  PARENT_LINKS = {
    "assessment_cycles" => { "cycle_id" => "cycle_id" },
    "calibration_sessions" => { "session_id" => "id" },
    "assessments" => { "person_id" => "person_id", "framework_id" => "framework_id" },
    "planning" => { "plan_id" => "id" },
    "users" => { "person_id" => "person_id" }
  }.freeze

  # Parents, or parent/child pairs, whose children reach them through a chain of ids, so they're
  # matched by tenant instead. That holds while the parent's tenant has one framework, which the crawl checks.
  TENANT_LINKED = {
    "frameworks" => "a framework's read models reach it through their parents' ids",
    "calibration_sessions/capabilities" => "a session's capabilities are those of its framework"
  }.freeze

  # Children that belong to the parent's tenant rather than to the parent, so the tenant alone narrows them.
  TENANT_WIDE = { "planning/budget_lines" => "a plan draws on its tenant's budget lines, which no plan owns" }.freeze

  # Route segments no seeded row fills, in either tenant. Each says why.
  UNSEEDED = {
    "suggestions/comments/:id" => "no factory or seed writes a suggestion comment's read model",
    "notifications/:id" => "a notification belongs to its recipient's account, not to a tenant",
    ":exploration_id" => "an exploration is opened only through an assessment's stream, which no factory writes",
    ":token" => "an evidence draft's token is no table's id"
  }.freeze

  # Pages a tenant admin who holds the plan's pay reaches with a redirect rather than a 200. Each says why.
  MEMBER_REDIRECTS = {
    "/tenant/cost_centre_rules/:id/edit" => "an entry is edited against the list version its page showed, which the crawl doesn't carry",
    "/planning/:id/update-to-today" => "a plan made today already stands on today, so the page sends its planner back to the changes"
  }.freeze

  # Pages served only inside a Turbo frame, with the frame each is asked for in.
  FRAMES = {
    "/planning/:id/timeline/figures" => "timeline-figures",
    "/planning/:plan_id/scenarios/:scenario_id/outcome" => "step-outcome"
  }.freeze

  # Pages that act on the scenario their query names. Each says why.
  SCENARIO_PAGES = {
    "/planning/:id/changes" => "the tab lists the changes of the scenario it names, where the seeded pay change and its note sit",
    "/planning/:id/budget/lines/new" => "a line is added to the scenario the Budget tab shows",
    "/planning/:id/budget/lines/:budget_line_id/edit" => "a line is changed in the scenario the Budget tab shows"
  }.freeze

  # Seeded pay figures, each also looked for with a thousands separator.
  PAY = %w[92417 84211].freeze

  # The routes a tenant's own planner should reach, and the planner's password.
  PLANNING_AND_ORG = %r{\A/(planning|tenant/(pay_bands|exchange_rates|budget_lines|cost_centre_rules|planning_inputs|org_graph))(/|\z)}
  PLANNER_PASSWORD = "planner-pass-1"

  UNTOUCHED_TABLES = %w[schema_migrations ar_internal_metadata].freeze
  # The account's own display and notification settings, which it may change without a tenant.
  OWN_SETTINGS = %w[color_scheme notification_preferences updated_at].freeze

  setup { seed }

  should "crawl every route, or exempt it with a reason" do
    uncrawlable = route_table.filter_map { |verb, path| "#{verb.upcase} #{path}" if path.include?("*") && !exempt?(path) }
    stale = EXEMPT.keys.reject { |pattern| route_table.any? { |_verb, path| path.match?(pattern) } }

    assert_empty uncrawlable, "a wildcard route can't be crawled: exempt it in EXEMPT with a reason"
    assert_empty stale, "an EXEMPT entry matches no route: remove it"
    assert(EXEMPT.values.all?(&:present?), "every EXEMPT entry gives a reason")
    assert_empty mounted_engines, "the crawl sees only an engine's mount point: exempt it, or crawl its own routes"
  end

  should "fill every route in each tenant with that tenant's own seeded rows, or say why it can't" do
    demo_tenants.each do |tenant|
      crawl(tenant)

      assert_empty unfilled(tenant).to_a - UNSEEDED.keys,
                   "in #{tenant.slug}, no seeded row fills these segments: seed one, add its source to SOURCES, or list it in UNSEEDED"
      assert_empty UNSEEDED.keys - unfilled(tenant).to_a, "in #{tenant.slug}, an UNSEEDED entry is now filled: remove it"
    end

    assert_empty SOURCES.keys - segments_seen.to_a, "a SOURCES entry names no route segment: remove it"
    assert_empty PARENT_LINKS.keys + TENANT_LINKED.keys + TENANT_WIDE.keys - links_used.to_a, "a link entry is used by no route: remove it"
    assert_empty GLOBAL_TABLES.keys - global_tables_used.to_a, "a GLOBAL_TABLES entry is drawn by no route: remove it"
    assert((UNSEEDED.values + TENANT_LINKED.values + TENANT_WIDE.values + GLOBAL_TABLES.values).all?(&:present?), "every entry gives a reason")
  end

  should "read no tenant's people, names, plans or pay on any page, and change nothing" do
    before = fingerprints
    leaks = []
    demo_tenants.each do |tenant|
      get_routes(tenant).each do |path|
        status, body = visit(:get, path)
        found = markers_in(body)
        leaks << "#{path} (#{status}): #{found.first(3).join(', ')}" if found.any?
      end
    end

    assert_empty errors, "a tenantless request raised"
    assert_empty leaks, "a tenantless account saw tenant data:\n#{leaks.join("\n")}"
    assert_equal before, fingerprints, "a tenantless read changed a table"
    get root_path
    assert_response :success, "the crawl should run signed in throughout"
  end

  should "be refused by every route that writes, in each tenant, and change nothing" do
    before = fingerprints
    answered = []
    assert_no_enqueued_jobs do
      assert_no_emails do
        demo_tenants.each do |tenant|
          write_routes(tenant).each do |verb, path, template|
            status, = visit(verb, path, params: body_for(template, path, tenant))
            next if refused?(status, template) || NOT_REFUSED.key?(template)

            answered << "#{tenant.slug}: #{verb.upcase} #{template} (#{status}#{" #{redirect_path}" if redirect_path && status.is_a?(Integer)})"
          end
        end
      end
    end

    assert_empty errors, "a tenantless request raised"
    assert_empty answered, "a write answered a tenantless account other than with a refusal"
    assert_empty (NOT_REFUSED.keys + REFUSED_ELSEWHERE.keys) - write_routes(demo_tenants.first).map(&:last), "an entry names no crawled write: remove it"
    assert_equal before, fingerprints, "a tenantless write changed a table"
    get root_path
    assert_response :success, "the crawl should run signed in throughout"
  end

  should "find tenant names on the same pages for a member, so the check above can fail" do
    delete destroy_user_session_path
    post user_session_path, params: { user: { email: "marisol@nullisland.example", password: ExampleSeed::PASSWORD } }

    seen = %w[/frameworks /assessments /calibration_sessions /tenant/users].select do |path|
      _status, body = visit(:get, path)
      markers_in(body).any?
    end

    assert_not_empty seen
  end

  should "show each tenant's plan, pay inputs, units and levels to its own planner on the routes the crawl fills" do
    demo_tenants.each do |tenant|
      delete destroy_user_session_path
      post user_session_path, params: { user: { email: planner_email(tenant), password: PLANNER_PASSWORD } }
      seen = Set.new
      pay_seen = false
      failed = planning_and_org_routes(tenant).filter_map do |template, path|
        path = "#{path}?scenario=#{seeded_id(":scenario_id", "scenarios", nil, tenant)}" if SCENARIO_PAGES.key?(template)
        status, body = visit(:get, path, headers: (FRAMES[template] && { "Turbo-Frame" => FRAMES[template] }))
        seen.merge(names_in(body, planning_names(tenant)))
        pay_seen ||= pay_in(body).any?
        next if status == 200 || (MEMBER_REDIRECTS.key?(template) && [ 302, 303 ].include?(status))

        "#{path} (#{status}#{" #{redirect_path}" if redirect_path && status.is_a?(Integer)} #{flash[:alert]})"
      end

      assert_empty errors, "a planner's request raised"
      assert_empty failed, "#{tenant.slug}'s planner should reach these pages"
      assert_empty planning_names(tenant) - seen.to_a, "#{tenant.slug}'s planner should see each seeded name on some page"
      assert pay_seen, "#{tenant.slug}'s planner should see the pay it holds"
    end
    assert(MEMBER_REDIRECTS.values.all?(&:present?), "every MEMBER_REDIRECTS entry gives a reason")
    assert(SCENARIO_PAGES.values.all?(&:present?), "every SCENARIO_PAGES entry gives a reason")
  end

  should "authorise no MCP client" do
    app = Mcp::Application.create!(name: "Client", redirect_uri: "https://client.example/cb", scopes: "read", confidential: false)
    tenant = ActsAsTenant.without_tenant { Tenant.first }
    params = { client_id: app.uid, redirect_uri: app.redirect_uri, response_type: "code", scope: "read",
               code_challenge: "x" * 43, code_challenge_method: "S256", state: "s", tenant_id: tenant.id }

    get oauth_authorization_path(params)
    assert_not_includes response.body, tenant.name

    assert_no_difference -> { Mcp::AccessGrant.count } do
      post oauth_authorization_path, params:
    end
  end

  should "not switch into a tenant it doesn't belong to" do
    tenant = ActsAsTenant.without_tenant { Tenant.first }

    post users_tenant_switch_path, params: { tenant_id: tenant.id }
    get root_path
    assert_not_includes response.body, tenant.name

    get "/tenant/users"
    assert refused?(response.status, nil), "a tenant page should still refuse the account"
  end

  private

  def seed
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    @admin = create(:user, global_admin: true)
    ExampleSeed.new(admin_user: @admin, io: StringIO.new).call
    demo_tenants.each { seed_tenant(it) }
    @account = create(:user, email: "nobody@example.com", password: "password-123", password_confirmation: "password-123")
    post user_session_path, params: { user: { email: @account.email, password: "password-123" } }
  end

  def demo_tenants = @demo_tenants ||= TENANTS.map { Tenant.find_by!(slug: it) }

  # Rows the example seed doesn't make in a tenant, so every route has one of that tenant's to crawl.
  def seed_tenant(tenant)
    ActsAsTenant.with_tenant(tenant) do
      planner_account(tenant)
      seed_framework(tenant)
      seed_development(tenant)
      seed_org_graph(tenant)
      seed_planning_inputs(tenant)
      seed_plan(tenant)
    end
    seed_mcp_approval(tenant)
  end

  # A draft in progress, so publishing reaches its permission check instead of turning back for want of one.
  def seed_framework(tenant)
    unless FrameworkState::Framework.exists?
      Rake::Task["frameworks:seed"].execute(Rake::TaskArguments.new(%i[file slug], [ "db/seeds/null_island_framework.yml", tenant.slug ]))
    end
    framework = FrameworkState::Framework.sole
    Frameworks::CommandHandler.new.start_draft(framework.framework_id, framework.current_published_version + 1, "seed") unless framework.draft?
  end

  # The crawl fills an assessment's routes with the tenant's first assessment, so its children belong to that one.
  def seed_development(tenant)
    framework = FrameworkState::Framework.sole
    unless PersonFrameworkAssignment.exists?
      level = FrameworkState::Level.order(:level_id).first!
      create(:person_framework_assignment, tenant:, person_id: create(:person, tenant:).id, framework_id: framework.framework_id,
                                           role_id: FrameworkState::Role.find_by!(role_id: level.role_id).role_id, level_id: level.level_id)
    end
    assessment = PersonFrameworkAssignment.order(:id).first!
    owner = { tenant:, person_id: assessment.person_id, framework_id: assessment.framework_id }
    create(:person_development_comment, **owner)
    create(:manager_assessment_delegation, **owner)
    item = create(:evidence_item, **owner, author: create(:person, tenant:))
    create(:evidence_placement_suggestion, tenant:, item:)
    create(:evidence_request, tenant:, framework_id: framework.framework_id) unless EvidenceRequest.exists?
    create(:framework_suggested_edit, tenant:, framework_id: framework.framework_id) unless FrameworkState::SuggestedEdit.exists?
    cycle = AssessmentCycle.first || create(:assessment_cycle, tenant:, framework_id: framework.framework_id)
    create(:assessment_cycle_enrollment, tenant:, cycle:, person_id: assessment.person_id) unless AssessmentCycleEnrollment.exists?
    session = create(:calibration_session, tenant:, framework_id: framework.framework_id, name: "#{label(tenant)} calibration round")
    create(:calibration_session_member, tenant:, session:)
    create(:calibration_session_member, :participant, tenant:, session:)
    seed_collaborators(tenant, framework)
  end

  # A collaborator for the tenant's first account with a person, so its collaborator routes have one.
  def seed_collaborators(tenant, framework)
    person_id = TenantUser.where.not(person_id: nil).order(:id).first!.person_id
    return if FrameworkState::Collaborator.exists?(person_id:)

    create(:framework_collaborator, tenant:, framework_id: framework.framework_id, person_id:)
  end

  def seed_org_graph(tenant)
    on = Date.current - 30
    ids = seeded(tenant).merge!(division: SecureRandom.uuid_v7, crew: SecureRandom.uuid_v7, watch: SecureRandom.uuid_v7,
                                harbour: SecureRandom.uuid_v7, lighthouse: SecureRandom.uuid_v7)
    structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    graph = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    structure.define_taxonomy([ { level_id: ids[:division], name: "#{label(tenant)} Division" },
                                { level_id: ids[:crew], name: "#{label(tenant)} Crew" } ], effective_on: on)
    structure.create_unit(ids[:harbour], "#{label(tenant)} Harbour", level_id: ids[:division], effective_on: on)
    structure.create_unit(ids[:lighthouse], "#{label(tenant)} Lighthouse", level_id: ids[:crew], parent_id: ids[:harbour], effective_on: on)
    planner = planner_account(tenant)
    watch = { level_id: ids[:watch], name: "#{label(tenant)} Watch", parent_level_ids: [ ids[:watch] ], top: true }
    OrgGraph::StructureCommandHandler.new(actor: context_of(planner)).declare_structure(ids[:lighthouse], levels: [ watch ], conversion: {}, effective_on: on)
    deckhand = create(:person, tenant:, name: "#{label(tenant)} Deckhand")
    [ planner.person, deckhand ].each do |person|
      graph.record_person(person.id, provider: "espalia", effective_on: on, employment_status: "employed")
      graph.set_membership(person.id, ids[:lighthouse], provider: "espalia", effective_on: on, allocation: 1)
    end
    %i[harbour lighthouse].each { structure.add_unit_owner(ids[it], planner.person_id, effective_on: on) }
    seeded(tenant)[:placed_person] = deckhand.id
  end

  def seed_planning_inputs(tenant)
    level = FrameworkState::Level.order(:level_id).first!
    add_pay_band!(level:, location: "#{label(tenant)} Quay", currency: "AUD", period: "year",
                  minimum: 70_000, midpoint: PAY.second.to_i, maximum: 99_000)
    add_planning_input!(:exchange_rates, from_currency: "NZD", to_currency: "AUD", rate: BigDecimal("0.9"), applies_from: Date.current - 30)
    add_planning_input!(:budget_lines, starts_on: Date.current, ends_on: Date.current + 365, origin: "new", amount: 120_000,
                                       currency: "AUD", period: "year", cost_centre: "#{label(tenant)} Ledger")
    add_planning_input!(:planning_rule_defaults, rule: "cost_centre",
                                                 value: { "entries" => [ { "location" => "#{label(tenant)} Quay", "cost_centre" => "#{label(tenant)} Ledger" } ] })
    seeded(tenant)[:cost_centre_place] = "0"
  end

  def seed_plan(tenant)
    planner = planner_account(tenant)
    ids = seeded(tenant)
    level = FrameworkState::Level.order(:level_id).first!
    plan_id = plan_call(Operations::TeamPlanning::CreatePlan, planner, name: "#{label(tenant)} harbour plan", base_on: Date.current.iso8601)[:plan_id]
    scenario_id = plan_call(Operations::TeamPlanning::ForkScenario, planner, plan_id:, relation: "then", name: "#{label(tenant)} spring",
                                                                             ends_on: (Date.current + 120).iso8601)[:scenario_id]
    ids[:position] = plan_call(Operations::TeamPlanning::SetPosition, planner, plan_id:, scenario_id:, role_id: level.role_id,
                                                                               level_id: level.level_id, unit_id: ids[:lighthouse], fte: 1, basis: "new")[:position_id]
    plan_call(Operations::TeamPlanning::SetPositionFunding, planner, plan_id:, scenario_id:, position_id: ids[:position],
                                                                     draws: [ { budget_line_id: BudgetLine.sole.id } ])
    plan_call(Operations::TeamPlanning::SetActualPay, planner, plan_id:, scenario_id:, person_id: ids[:placed_person],
                                                               amount: PAY.first, currency: "AUD", period: "year", basis: "full_time")
    pay = plan_call(Operations::TeamPlanning::History, planner, plan_id:, scenario_id:)[:entries].find { it[:facet] == "data:pay" }
    plan_call(Operations::TeamPlanning::NoteChange, planner, plan_id:, scenario_id:, event_id: pay[:event_id], note: "#{label(tenant)} pay note")
  end

  def seed_mcp_approval(tenant)
    client = Mcp::Application.find_or_create_by!(name: "Crawl client") do |app|
      app.redirect_uri = "https://client.example/cb"
      app.scopes = "read"
      app.confidential = false
    end
    token = Mcp::AccessToken.create!(application: client, resource_owner_id: @admin.id, tenant_id: tenant.id, scopes: "read", expires_in: 3600)
    as_mcp_call_with(token) do
      Mcp::PendingApproval.create!(user: @admin, tenant:, client_application: client, operation_class: "Operations::System::Whoami",
                                   arguments: {}, expires_at: 1.hour.from_now)
    end
  end

  def label(tenant) = tenant.slug.capitalize
  def seeded(tenant) = (@seeded ||= {})[tenant.id] ||= {}
  def planner_email(tenant) = "planner@#{tenant.slug}.example"

  # A tenant admin with a person, who creates the tenant's plan and so holds its pay.
  def planner_account(tenant)
    seeded(tenant)[:planner] ||= begin
      user = create(:user, email: planner_email(tenant), password: PLANNER_PASSWORD, password_confirmation: PLANNER_PASSWORD)
      create(:tenant_user, tenant:, user:, role: :admin, person: create(:person, tenant:, name: "#{label(tenant)} Planner", email: user.email))
    end
  end

  def plan_call(operation, account, **params) = operation.call(context: context_of(account), params:)
  def context_of(account) = AuthorizationContext.new(user: account.user, tenant_user: account, person: account.person)

  # The names the planning and Org Graph setup gives a tenant, which its planner should see.
  def planning_names(tenant)
    [ "harbour plan", "spring", "Division", "Crew", "Watch", "Harbour", "Lighthouse", "Quay", "Ledger", "pay note" ]
      .map { "#{label(tenant)} #{it}" }
  end

  def pay_figures = PAY + PAY.map { it.to_i.to_fs(:delimited) }

  def errors = @errors ||= []

  # Any exception is kept with its path, so one route can't hide the rest of the crawl.
  def visit(verb, path, params: nil, headers: nil)
    send(verb, path, params:, headers:)
    [ response.status, response.body.to_s ]
  rescue StandardError => e
    errors << "#{verb.upcase} #{path}: #{e.class}: #{e.message.lines.first&.strip}"
    [ e.class.name, "" ]
  end

  def refused?(status, template)
    return true if [ 401, 403, 404 ].include?(status)
    return false unless [ 302, 303 ].include?(status)

    REFUSAL_PATHS.include?(redirect_path) || REFUSED_ELSEWHERE[template]&.first&.match?(redirect_path)
  end

  def redirect_path = response.location && URI(response.location).path

  def route_table
    @route_table ||= Rails.application.routes.routes.flat_map do |route|
      path = route.path.spec.to_s.sub("(.:format)", "").gsub(/\(.*?\)/, "")
      route.verb.to_s.downcase.split("|").presence&.map { [ it.to_sym, path ] } || [ [ :get, path ] ]
    end.uniq
  end

  def mounted_engines
    Rails.application.routes.routes.filter_map do |route|
      app = route.app.respond_to?(:app) ? route.app.app : route.app
      route.path.spec.to_s if app.is_a?(Class) && app < Rails::Engine && !exempt?(route.path.spec.to_s)
    end
  end

  def exempt?(path) = EXEMPT.keys.any? { path.match?(it) }

  def crawl(tenant)
    (@crawls ||= {})[tenant.id] ||= route_table.filter_map do |verb, path|
      [ verb, fill(path, tenant), path ] unless exempt?(path) || path.include?("*")
    end
  end

  def get_routes(tenant) = crawl(tenant).filter_map { |verb, path| path if verb == :get }
  def write_routes(tenant) = crawl(tenant).reject { |verb, path| verb == :get || path == destroy_user_session_path }

  def planning_and_org_routes(tenant)
    crawl(tenant).filter_map { |verb, path, template| [ template, path ] if verb == :get && template.match?(PLANNING_AND_ORG) }
  end

  def unfilled(tenant) = (@unfilled ||= {})[tenant.id] ||= Set.new
  def segments_seen = @segments_seen ||= Set.new
  def links_used = @links_used ||= Set.new
  def global_tables_used = @global_tables_used ||= Set.new

  # Replaces each id segment with the id of a row of the tenant's, under the row its parent segment drew.
  def fill(path, tenant)
    parent = nil
    path.gsub(%r{(\w+)/:(\w+)}) do
      collection, param = Regexp.last_match.captures
      segment = param == "id" ? [ parent&.first, collection, ":id" ].compact.join("/") : ":#{param}"
      child = param == "id" ? collection : param.delete_suffix("_id").pluralize
      value = special(param, tenant)
      unless value
        segments_seen << segment
        value = seeded_id(segment, child, parent, tenant)
        unfilled(tenant) << segment unless value
      end
      source = SOURCES[segment]
      parent = [ collection, value, *(source.first(2) if source.is_a?(Array)) ]
      "#{collection}/#{value || SecureRandom.uuid_v7}"
    end
  end

  def special(param, tenant)
    case param
    when "tenant_slug" then tenant.slug
    when "card" then "team"
    when "inputs" then "pay_bands"
    when "fact" then OrgGraph::StructureAggregate::MAPPABLE_FIELDS.keys.first
    end
  end

  # The id a segment's source holds for a row of the tenant's under the parent's row.
  # parent is [collection, value, table, column], where value is nil when nothing filled it.
  def seeded_id(segment, child, parent, tenant)
    return "hris" if segment == "integrations/:id"

    source = SOURCES[segment]
    return seeded(tenant)[source]&.to_s if source.is_a?(Symbol)
    return unless source

    table, column, condition = source
    (@seeded_ids ||= {}).fetch([ segment, parent, tenant.id ]) do
      conditions = [ tenant_condition(table, tenant), condition, parent_link(table, child, parent) ].compact
      @seeded_ids[[ segment, parent, tenant.id ]] = first_value(table, column, conditions)
    end
  end

  def tenant_condition(table, tenant)
    unless connection.column_exists?(table, "tenant_id")
      assert GLOBAL_TABLES.key?(table), "#{table} holds no tenant_id: list it in GLOBAL_TABLES with a reason"
      global_tables_used << table
      return
    end

    "tenant_id = #{connection.quote(tenant.id)}"
  end

  # SQL limiting a child table to the parent's row, or nil when the child has no parent row to follow.
  def parent_link(table, child, parent)
    parent_collection, parent_value, parent_table, parent_column = parent
    return unless parent_value && parent_table

    parent_row = "SELECT %s FROM #{connection.quote_table_name(parent_table)} WHERE #{column_sql(parent_column)} = #{connection.quote(parent_value)}"
    link = parent_link_columns(table, child, parent_collection, parent_column, parent_row)
    return if link.empty?

    link.map { |child_column, column| "#{connection.quote_column_name(child_column)} IN (#{parent_row % connection.quote_column_name(column)})" }
        .join(" AND ")
  end

  def parent_link_columns(table, child, parent_collection, parent_column, parent_row)
    return {}.tap { links_used << "#{parent_collection}/#{child}" } if TENANT_WIDE.key?("#{parent_collection}/#{child}")

    links_used << parent_collection if PARENT_LINKS.key?(parent_collection)
    link = PARENT_LINKS.fetch(parent_collection) { { "#{parent_collection.singularize}_id" => parent_column } }
    return link if link.keys.all? { connection.column_exists?(table, it) }

    key = [ "#{parent_collection}/#{child}", parent_collection ].find { TENANT_LINKED.key?(it) }
    raise "#{table} holds no link to #{parent_collection}: map it in PARENT_LINKS or TENANT_LINKED" unless
      key && connection.column_exists?(table, "tenant_id")

    links_used << key
    frameworks = connection.select_value("SELECT count(*) FROM framework_states WHERE tenant_id IN (#{parent_row % 'tenant_id'})")
    assert_equal 1, frameworks, "#{parent_collection}'s tenant holds #{frameworks} frameworks, so its tenant no longer names one"
    { "tenant_id" => "tenant_id" }
  end

  def column_sql(column) = column.match?(/\A\w+\z/) ? connection.quote_column_name(column) : column

  def first_value(table, column, conditions)
    expression = column_sql(column)
    connection.select_value("SELECT #{expression} FROM #{connection.quote_table_name(table)} " \
                            "#{"WHERE #{conditions.join(' AND ')}" if conditions.any?} ORDER BY #{expression} LIMIT 1")
  end

  def body_for(template, path, tenant)
    return {} unless BODIES.key?(template)

    collection, value = path.scan(%r{(\w+)/([^/]+)}).last
    parent = [ collection, value, *SOURCES.fetch("#{collection}/:id").first(2) ]
    BODIES[template].transform_values do |fields|
      fields.transform_values do |source|
        seeded_id(source, source.split("/")[-2], parent, tenant).tap { assert it, "#{template} found no #{source} to send" }
      end
    end
  end

  # Names, addresses and words only a tenant's members should see.
  def leak_names
    @leak_names ||= ActsAsTenant.without_tenant do
      names = Tenant.pluck(:name) + Person.pluck(:name, :email).flatten + FrameworkState::Framework.pluck(:name) +
              FrameworkState::Capability.pluck(:name, :description).flatten + FrameworkState::Role.pluck(:name) +
              EvidenceItem.pluck(:content) + PersonDevelopmentComment.pluck(:body) +
              OrgUnit.pluck(:name) + AssessmentCycle.pluck(:name) + CalibrationSession.pluck(:name) +
              demo_tenants.flat_map { planning_names(it) }
      names.compact.uniq.select { it.length > 3 }
    end
  end

  def markers_in(body) = names_in(body, leak_names) + pay_in(body)

  def names_in(body, names) = names.select { body.include?(it) || body.include?(ERB::Util.html_escape(it)) }

  # Ids are taken out first, so a UUID or digest holding the digits doesn't count as pay.
  def pay_in(body)
    text = PayFigureAssertions.without_ids(body)
    pay_figures.select { text.include?(it) }
  end

  # A checksum of every row, so an update counts as well as an insert or a delete. The crawling
  # account's own settings may change; every other user's are checked like any other column.
  def fingerprints
    (connection.tables - UNTOUCHED_TABLES).sort.index_with do |table|
      columns = connection.columns(table).map(&:name)
      next checksum(table, columns) unless table == "users"

      own = "id = #{connection.quote(@account.id)}"
      [ checksum(table, columns, "NOT (#{own})"), checksum(table, columns - OWN_SETTINGS, own) ]
    end
  end

  def checksum(table, columns, condition = "TRUE")
    row = "row(#{columns.map { connection.quote_column_name(it) }.join(', ')})::text"
    connection.select_value("SELECT md5(coalesce(string_agg(#{row}, '|' ORDER BY #{row}), '')) FROM #{connection.quote_table_name(table)} WHERE #{condition}")
  end

  def connection = ActiveRecord::Base.connection
end
