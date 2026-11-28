# frozen_string_literal: true

require "test_helper"
require "rake"
require_relative "../../lib/tasks/example_seed"

# A signed-in account that belongs to no tenant runs every request with no
# current tenant, where acts_as_tenant scopes nothing. These tests walk every
# route with ids from two seeded tenants and check that such an account reads
# none of their data and changes nothing.
class TenantlessAccountTest < ActionDispatch::IntegrationTest
  OUT_OF_SCOPE = %r{\A/(rails|inspect|preview|previews|lookbook|embed|pages|up|\.well-known|api/feedback_exchange|users/auth|t/)}
  WATCHED_TABLES = %w[
    event_store_events tenants tenant_users people users
    oauth_access_grants oauth_access_tokens oauth_applications mcp_pending_approvals
  ].freeze

  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    ExampleSeed.new(admin_user: create(:user, global_admin: true), io: StringIO.new).call
    @account = create(:user, email: "nobody@example.com", password: "password-123", password_confirmation: "password-123")
    post user_session_path, params: { user: { email: @account.email, password: "password-123" } }
  end

  should "read no tenant's people, names or settings on any page" do
    leaks = []
    get_routes.each do |path|
      status, body = visit(:get, path)
      found = tenant_names.select { |name| body.include?(name) || body.include?(ERB::Util.html_escape(name)) }
      leaks << "#{path} (#{status}): #{found.first(3).join(', ')}" if found.any?
      landings << "#{status} #{path} -> #{response.location || response.media_type}" if ENV["TENANTLESS_LOG"]
    end
    File.write(ENV["TENANTLESS_LOG"], landings.join("\n")) if ENV["TENANTLESS_LOG"]

    assert_empty leaks, "a tenantless account saw tenant data:\n#{leaks.join("\n")}"
  end

  should "change nothing through any route that writes" do
    before = row_counts
    write_routes.each { |verb, path| visit(verb, path) }

    assert_equal before, row_counts
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
  end

  private

  def landings = @landings ||= []

  def visit(verb, path)
    send(verb, path)
    [ response.status, response.body.to_s ]
  rescue ActiveRecord::RecordNotFound, ActionController::RoutingError, ActionController::ParameterMissing,
         ActionController::BadRequest, ActionDispatch::Http::Parameters::ParseError => e
    [ e.class.name, "" ]
  end

  def routes
    Rails.application.routes.routes.filter_map do |route|
      verb = route.verb.to_s.downcase
      path = route.path.spec.to_s.sub("(.:format)", "")
      next if verb.empty? || path.match?(OUT_OF_SCOPE) || path.include?("*")

      [ verb.split("|").first.to_sym, fill(path.gsub(/\(.*?\)/, "")) ]
    end.uniq
  end

  def get_routes = routes.filter_map { |verb, path| path if verb == :get }
  def write_routes = routes.reject { |verb, path| verb == :get || path == destroy_user_session_path }

  def fill(path)
    path.gsub(%r{(\w+)/:(\w+)}) do
      collection, param = Regexp.last_match.captures
      value = param == "id" ? record_ids[collection] : ids[param.to_sym]
      "#{collection}/#{value || SecureRandom.uuid_v7}"
    end
  end

  def record_ids
    @record_ids ||= ActsAsTenant.without_tenant do
      {
        "assessment_cycles" => AssessmentCycle.first&.id, "assessments" => PersonFrameworkAssignment.first&.id,
        "calibration_sessions" => CalibrationSession.first&.id, "capabilities" => FrameworkState::Capability.first&.capability_id,
        "comments" => PersonDevelopmentComment.first&.id, "items" => EvidenceItem.first&.id,
        "requests" => EvidenceRequest.first&.id, "frameworks" => FrameworkState::Framework.first&.framework_id,
        "suggestions" => FrameworkState::SuggestedEdit.first&.id, "approvals" => Mcp::PendingApproval.first&.id,
        "applications" => Mcp::Application.first&.id, "planning" => TeamPlanningPlan.first&.plan_id,
        "budget_lines" => BudgetLine.first&.id, "exchange_rates" => ExchangeRate.first&.id,
        "pay_bands" => PayBand.first&.id, "people" => Person.first&.id, "units" => OrgUnit.first&.id,
        "users" => TenantUser.first&.id, "integrations" => "hris"
      }
    end
  end

  def ids
    @ids ||= ActsAsTenant.without_tenant do
      plan = TeamPlanningPlan.first
      {
        id: AssessmentCycle.first&.id, assessment_id: PersonFrameworkAssignment.first&.id,
        assignment_id: PersonFrameworkAssignment.first&.id, evidence_id: EvidenceItem.first&.id,
        calibration_session_id: CalibrationSession.first&.id, person_id: Person.first&.id,
        framework_id: FrameworkState::Framework.first&.framework_id, capability_id: FrameworkState::Capability.first&.capability_id,
        plan_id: plan&.plan_id, scenario_id: TeamPlanningScenario.first&.scenario_id,
        org_unit_id: OrgUnit.first&.id, level_id: FrameworkState::Level.first&.level_id,
        budget_line_id: BudgetLine.first&.id, tenant_slug: Tenant.first&.slug, card: "team", inputs: "pay_bands"
      }.compact
    end
  end

  def tenant_names
    @tenant_names ||= ActsAsTenant.without_tenant do
      (Tenant.pluck(:name) + Person.pluck(:name) + FrameworkState::Framework.pluck(:name) +
       OrgUnit.pluck(:name) + AssessmentCycle.pluck(:name) + CalibrationSession.pluck(:name))
        .compact.uniq.select { it.length > 3 }
    end
  end

  def row_counts
    WATCHED_TABLES.index_with { ActiveRecord::Base.connection.select_value("SELECT count(*) FROM #{it}") }
  end
end
