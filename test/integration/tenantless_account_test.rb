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
    "/frameworks/:framework_id/capability_archives" => { archive: { capability_id: :capability_id } },
    "/frameworks/:framework_id/category_archives" => { archive: { category_id: :category_id } },
    "/frameworks/:framework_id/illustration_archives" => { archive: { illustration_id: :illustration_id } }
  }.freeze

  # Collections whose table name doesn't end in the route's word.
  TABLES = {
    "applications" => "oauth_applications", "approvals" => "mcp_pending_approvals",
    "assessments" => "person_framework_assignments", "assignments" => "person_framework_assignments",
    "assessments/comments" => "person_development_comments", "evidence" => "evidence_items",
    "items" => "evidence_items", "requests" => "evidence_requests", "frameworks" => %w[framework_states framework_id],
    "planning" => "team_planning_plans", "scenarios" => "team_planning_scenarios", "suggestions" => "framework_suggested_edits",
    "notifications" => "noticed_notifications", "units" => "org_units", "users" => "tenant_users",
    "org_people" => "people", "illustrations" => %w[framework_role_illustrations illustration_id],
    "categories" => %w[framework_capability_categories category_id], "evidences" => "evidence_items",
    "comments" => "person_development_comments", "suggestions/comments" => "framework_suggestion_comments",
    "capability_bindings" => %w[framework_capability_role_bindings binding_id],
    "calibrants" => %w[calibration_session_members person_id], "participants" => %w[calibration_session_members person_id],
    "delegations" => "manager_assessment_delegations", "connected_clients" => "oauth_access_tokens",
    "members" => "org_memberships", "memberships" => "org_memberships", "owners" => "org_unit_owners"
  }.freeze

  # Parents whose children link to them other than by `<parent>_id`, as child column => parent column.
  PARENT_LINKS = {
    "assessment_cycles" => { "cycle_id" => "cycle_id" },
    "calibration_sessions" => { "session_id" => "id" },
    "assessments" => { "person_id" => "person_id", "framework_id" => "framework_id" },
    "users" => { "person_id" => "person_id" }
  }.freeze

  # Parents, or parent/child pairs, whose children reach them through a chain of ids, so they're
  # matched by tenant instead. That holds while the parent's tenant has one framework, which the crawl checks.
  TENANT_LINKED = {
    "frameworks" => "a framework's read models reach it through their parents' ids",
    "calibration_sessions/capabilities" => "a session's capabilities are those of its framework"
  }.freeze

  # Org Graph routes whose word names a different table than elsewhere.
  ORG_GRAPH_TABLES = { "levels" => "org_taxonomy_levels" }.freeze

  # Route segments no seeded record fills. Each says why.
  NO_PLAN = "the example seed makes no Team Planning plan"
  NO_UNIT = "the example seed records people in the Org Graph but no units"
  NO_INPUTS = "the example seed sets none of the tenant's planning inputs"
  NO_LEVEL = "the example seed defines no Org Graph levels"
  UNSEEDED = {
    ":plan_id" => NO_PLAN,
    "planning/:id" => NO_PLAN,
    ":scenario_id" => NO_PLAN,
    "planning/scenarios/:id" => NO_PLAN,
    "planning/positions/:id" => NO_PLAN,
    "planning/fundings/:id" => NO_PLAN,
    "planning/see_pay/:id" => NO_PLAN,
    "planning/notes/:id" => NO_PLAN,
    ":org_unit_id" => NO_UNIT,
    "units/:id" => NO_UNIT,
    "units/members/:id" => NO_UNIT,
    "units/owners/:id" => NO_UNIT,
    "people/memberships/:id" => NO_UNIT,
    "pay_bands/:id" => NO_INPUTS,
    "exchange_rates/:id" => NO_INPUTS,
    "cost_centre_rules/:id" => NO_INPUTS,
    "budget_lines/:id" => NO_INPUTS,
    ":budget_line_id" => NO_INPUTS,
    "suggestions/comments/:id" => "the example seed's suggestions carry no comments",
    "notifications/:id" => "the example seed sends no notifications",
    ":exploration_id" => "the example seed opens no exploration",
    "users/collaborators/:id" => "a collaborator's route id joins its framework, role and scope, which no column holds",
    "levels/:id" => NO_LEVEL,
    ":level_id" => NO_LEVEL,
    ":token" => "the example seed leaves no evidence draft, and a draft's token is no table's id"
  }.freeze

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
  end

  should "fill every route with the id of a seeded record, or say why it can't" do
    crawl

    assert_empty unfilled.to_a - UNSEEDED.keys, "no seeded record fills these segments: seed one, map it in TABLES, or list it in UNSEEDED"
    assert_empty UNSEEDED.keys - unfilled.to_a, "an UNSEEDED entry is now filled: remove it"
    assert_empty PARENT_LINKS.keys + TENANT_LINKED.keys - links_used.to_a, "a link entry is used by no route: remove it"
    assert(TENANT_LINKED.values.all?(&:present?), "every TENANT_LINKED entry gives a reason")
  end

  should "read no tenant's people, names or settings on any page" do
    leaks = []
    get_routes.each do |path|
      status, body = visit(:get, path)
      found = tenant_names.select { |name| body.include?(name) || body.include?(ERB::Util.html_escape(name)) }
      leaks << "#{path} (#{status}): #{found.first(3).join(', ')}" if found.any?
    end

    assert_empty errors, "a tenantless request raised"
    assert_empty leaks, "a tenantless account saw tenant data:\n#{leaks.join("\n")}"
  end

  should "be refused by every route that writes, and change nothing" do
    before = fingerprints
    answered = nil
    assert_no_enqueued_jobs do
      assert_no_emails do
        answered = write_routes.filter_map do |verb, path, template|
          status, = visit(verb, path, params: body_for(template, path))
          "#{verb.upcase} #{template} (#{status}#{" #{redirect_path}" if redirect_path && status.is_a?(Integer)})" unless refused?(status, template) || NOT_REFUSED.key?(template)
        end
      end
    end

    assert_empty errors, "a tenantless request raised"
    assert_empty answered, "a write answered a tenantless account other than with a refusal"
    assert_empty (NOT_REFUSED.keys + REFUSED_ELSEWHERE.keys) - write_routes.map(&:last), "an entry names no crawled write: remove it"
    assert_equal before, fingerprints, "a tenantless write changed a table"
    get root_path
    assert_response :success, "the crawl should run signed in throughout"
  end

  should "find tenant names on the same pages for a member, so the check above can fail" do
    delete destroy_user_session_path
    post user_session_path, params: { user: { email: "marisol@nullisland.example", password: ExampleSeed::PASSWORD } }

    seen = %w[/frameworks /assessments /calibration_sessions /tenant/users].select do |path|
      _status, body = visit(:get, path)
      tenant_names.any? { body.include?(it) || body.include?(ERB::Util.html_escape(it)) }
    end

    assert_not_empty seen
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
    seed_second_tenant
    @account = create(:user, email: "nobody@example.com", password: "password-123", password_confirmation: "password-123")
    post user_session_path, params: { user: { email: @account.email, password: "password-123" } }
  end

  # Rows the example seed doesn't make, so the routes that read them have a record to crawl.
  def seed_second_tenant
    tenant = Tenant.find_by!(slug: ExampleSeed::SECOND_TENANT[:slug])
    ActsAsTenant.with_tenant(tenant) do
      create(:evidence_placement_suggestion, tenant:)
    end
    seed_under_first_assessment
    client = Mcp::Application.create!(name: "Crawl client", redirect_uri: "https://client.example/cb", scopes: "read", confidential: false)
    token = Mcp::AccessToken.create!(application: client, resource_owner_id: @admin.id, tenant_id: tenant.id, scopes: "read", expires_in: 3600)
    as_mcp_call_with(token) do
      Mcp::PendingApproval.create!(user: @admin, tenant:, client_application: client, operation_class: "Operations::System::Whoami",
                                   arguments: {}, expires_at: 1.hour.from_now)
    end
  end

  # The crawl fills an assessment's routes with the first assessment, so its children belong to that one,
  # and a calibration session in its framework.
  def seed_under_first_assessment
    assessment = ActsAsTenant.without_tenant { PersonFrameworkAssignment.order(:id).first! }
    ActsAsTenant.with_tenant(assessment.tenant) do
      owner = { tenant: assessment.tenant, person_id: assessment.person_id, framework_id: assessment.framework_id }
      create(:person_development_comment, **owner)
      create(:manager_assessment_delegation, **owner)
      create(:evidence_item, **owner, author: create(:person, tenant: assessment.tenant))
      session = create(:calibration_session, tenant: assessment.tenant, framework_id: assessment.framework_id, name: "Crawl round")
      create(:calibration_session_member, tenant: assessment.tenant, session:)
      create(:calibration_session_member, :participant, tenant: assessment.tenant, session:)
    end
  end

  def errors = @errors ||= []

  # Any exception is kept with its path, so one route can't hide the rest of the crawl.
  def visit(verb, path, params: nil)
    send(verb, path, params:)
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
    Rails.application.routes.routes.map do |route|
      verb = route.verb.to_s.downcase.split("|").first || "get"
      [ verb.to_sym, route.path.spec.to_s.sub("(.:format)", "").gsub(/\(.*?\)/, "") ]
    end.uniq
  end

  def exempt?(path) = EXEMPT.keys.any? { path.match?(it) }

  def crawl
    @crawl ||= route_table.filter_map { |verb, path| [ verb, fill(path), path ] unless exempt?(path) || path.include?("*") }
  end

  def get_routes = crawl.filter_map { |verb, path| path if verb == :get }
  def write_routes = crawl.reject { |verb, path| verb == :get || path == destroy_user_session_path }

  def unfilled = @unfilled ||= Set.new

  def fill(path)
    parent = nil
    scope = path.include?("/org_graph/") ? ORG_GRAPH_TABLES : {}
    path.gsub(%r{(\w+)/:(\w+)}) do
      collection, param = Regexp.last_match.captures
      key = param == "id" ? collection : param.delete_suffix("_id").pluralize
      value = special(collection, param) ||
              (seeded_id(key, parent, scope) if param == "id" || param.end_with?("_id"))
      unfilled << (param == "id" ? [ parent&.first, collection, ":id" ].compact.join("/") : ":#{param}") unless value
      parent = [ collection, value, *(seeded_source(key, parent&.first, scope) unless special(collection, param)) ]
      "#{collection}/#{value || SecureRandom.uuid_v7}"
    end
  end

  def special(collection, param)
    case [ collection, param ]
    in [ _, "tenant_slug" ] then ActsAsTenant.without_tenant { Tenant.first&.slug }
    in [ _, "card" ] then "team"
    in [ _, "inputs" ] then "pay_bands"
    in [ _, "fact" ] then OrgGraph::StructureAggregate::MAPPABLE_FIELDS.keys.first
    in [ "integrations", "id" ] then "hris"
    else nil
    end
  end

  # The routing id of a seeded row in the table the collection names, under the parent's row.
  # parent is [collection, value, table, column], where value is nil when nothing filled it.
  def seeded_id(collection, parent, scope = {})
    @seeded_ids ||= {}
    @seeded_ids.fetch([ collection, parent, scope ]) do
      table, column = seeded_source(collection, parent&.first, scope)
      @seeded_ids[[ collection, parent, scope ]] = table && first_value(table, column, parent_link(table, collection, parent))
    end
  end

  def seeded_source(collection, parent, scope)
    table, column = table_for(collection, parent, scope)
    table && [ table, column || routing_column(table, collection) ]
  end

  # SQL limiting a child table to the parent's row, or nil when the child has no parent row to follow.
  def parent_link(table, collection, parent)
    parent_collection, parent_value, parent_table, parent_column = parent
    return unless parent_value && parent_table

    parent_row = "SELECT %s FROM #{connection.quote_table_name(parent_table)} " \
                 "WHERE #{connection.quote_column_name(parent_column)} = #{connection.quote(parent_value)}"
    link = parent_link_columns(table, collection, parent_collection, parent_column, parent_row)
    link.map { |child_column, column| "#{connection.quote_column_name(child_column)} IN (#{parent_row % connection.quote_column_name(column)})" }
        .join(" AND ")
  end

  def parent_link_columns(table, collection, parent_collection, parent_column, parent_row)
    links_used << parent_collection if PARENT_LINKS.key?(parent_collection)
    link = PARENT_LINKS.fetch(parent_collection) { { "#{parent_collection.singularize}_id" => parent_column } }
    return link if link.keys.all? { connection.column_exists?(table, it) }

    key = [ "#{parent_collection}/#{collection}", parent_collection ].find { TENANT_LINKED.key?(it) }
    raise "#{table} holds no link to #{parent_collection}: map it in PARENT_LINKS or TENANT_LINKED" unless
      key && connection.column_exists?(table, "tenant_id")

    links_used << key
    frameworks = connection.select_value("SELECT count(*) FROM framework_states WHERE tenant_id IN (#{parent_row % 'tenant_id'})")
    assert_equal 1, frameworks, "#{parent_collection}'s tenant holds #{frameworks} frameworks, so its tenant no longer names one"
    { "tenant_id" => "tenant_id" }
  end

  def links_used = @links_used ||= Set.new

  def table_for(collection, parent, scope)
    mapped = scope[collection] || TABLES["#{parent}/#{collection}"] || TABLES[collection]
    return Array(mapped) if mapped

    candidates = connection.tables.select { it == collection || it.end_with?("_#{collection}") }
    candidates = candidates.select { it.include?(parent.singularize) }.presence || candidates if parent
    raise "#{parent}/#{collection} could name #{candidates.to_sentence}: map it in TABLES" if candidates.many?

    candidates
  end

  # Framework read models route by the stable id their events carry; every other table by its primary key.
  def routing_column(table, collection)
    columns = connection.columns(table).map(&:name)
    return "id" unless table.start_with?("framework_")

    [ "#{collection.singularize}_id", "#{table.split('_').last.singularize}_id" ].find { columns.include?(it) } || "id"
  end

  def first_value(table, column, condition)
    quoted = connection.quote_column_name(column)
    connection.select_value("SELECT #{quoted} FROM #{connection.quote_table_name(table)} " \
                            "#{"WHERE #{condition}" if condition} ORDER BY #{quoted} LIMIT 1")
  end

  def body_for(template, path)
    return {} unless BODIES.key?(template)

    collection, value = path.scan(%r{(\w+)/([^/]+)}).last
    parent = [ collection, value, *seeded_source(collection, nil, {}) ]
    BODIES[template].transform_values do |fields|
      fields.transform_values { seeded_id(it.to_s.delete_suffix("_id").pluralize, parent) }
    end
  end

  def tenant_names
    @tenant_names ||= ActsAsTenant.without_tenant do
      (Tenant.pluck(:name) + Person.pluck(:name) + FrameworkState::Framework.pluck(:name) +
       OrgUnit.pluck(:name) + AssessmentCycle.pluck(:name) + CalibrationSession.pluck(:name))
        .compact.uniq.select { it.length > 3 }
    end
  end

  # A checksum of every row, so an update counts as well as an insert or a delete.
  def fingerprints
    (connection.tables - UNTOUCHED_TABLES).sort.index_with do |table|
      columns = connection.columns(table).map(&:name)
      columns -= OWN_SETTINGS if table == "users"
      row = "row(#{columns.map { connection.quote_column_name(it) }.join(', ')})::text"
      connection.select_value("SELECT md5(coalesce(string_agg(#{row}, '|' ORDER BY #{row}), '')) FROM #{connection.quote_table_name(table)}")
    end
  end

  def connection = ActiveRecord::Base.connection
end
