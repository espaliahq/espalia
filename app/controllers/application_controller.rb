# frozen_string_literal: true

class ApplicationController < ActionController::Base
  include Pundit::Authorization
  include Impersonatable
  include Pagy::Method
  include DevThemeOverride
  include ColorSchemePreference

  set_current_tenant_through_filter

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  before_action :authenticate_user!
  before_action :set_tenant
  before_action :enforce_impersonation_read_only
  around_action :wrap_with_audit_metadata

  rescue_from Pundit::NotAuthorizedError, with: :user_not_authorized

  private

  # Resolves the TenantUser the request should act as, honouring an active
  # impersonation session (see {Impersonatable}). Falls back to the real
  # admin's own membership. Cached per request.
  #
  # @return [TenantUser, nil]
  def current_tenant_user
    return @current_tenant_user if defined?(@current_tenant_user)
    @current_tenant_user = effective_tenant_user
  end

  # Resolves the Person domain entity for the current user in the active tenant.
  # Cached per request. Returns nil if no linked Person exists.
  #
  # @return [Person, nil]
  def current_person
    return @current_person if defined?(@current_person)
    @current_person = current_tenant_user&.person
  end

  helper_method :current_tenant_user, :current_person

  # Builds the Pundit authorization context carrying the full identity chain.
  #
  # @return [AuthorizationContext]
  def pundit_user
    AuthorizationContext.new(
      user: effective_user,
      tenant_user: current_tenant_user,
      person: current_person
    )
  end

  # Handles Pundit authorization failures.
  #
  # A Turbo Frame `src` fetch cannot follow a redirect — Turbo looks for the
  # requested frame in the redirect target, doesn't find it, logs "the response
  # did not contain the expected <turbo-frame>", and leaves that section of the
  # UI broken. So for frame requests we render the requested frame with a
  # recoverable message instead of redirecting; everything else redirects as
  # before.
  #
  # @param _exception [Pundit::NotAuthorizedError]
  # @return [void]
  def user_not_authorized(_exception = nil)
    if turbo_frame_request?
      render_turbo_frame_recovery("You don't have access to this section, or your session has changed.")
    else
      redirect_back fallback_location: root_path, alert: "You are not authorized to perform this action."
    end
  end

  # Renders the requested Turbo Frame wrapping a recoverable message + a
  # top-level reload link, so a denied/expired frame fetch degrades into a
  # clean refresh rather than a silent broken frame. Intentionally NOT
  # auto-reloading — a persistently-denied frame would otherwise loop.
  #
  # @param message [String]
  # @return [void]
  def render_turbo_frame_recovery(message)
    content = helpers.turbo_frame_tag(turbo_frame_request_id) do
      helpers.safe_join([
        helpers.tag.p(message, class: "p-4 text-sm text-gray-600 dark:text-gray-300"),
        # `url_from` returns the referer only if it's same-origin (or relative),
        # else nil — the Referer header is attacker-controllable, so never link
        # to it raw. Falls back to root_path for off-site / missing referers.
        helpers.link_to("Reload", url_from(request.referer) || root_path,
          data: { turbo_frame: "_top" },
          class: "mx-4 mb-4 inline-block text-sm font-medium text-primary-ink underline")
      ])
    end
    render html: content, layout: false
  end

  # Ensures the TenantUser has a linked Person — the invariant that lets
  # domain-authored columns be foreign keys to people(id). Delegates to
  # TenantUser#ensure_person! which is also used from seeds/other non-web
  # paths.
  #
  # Best-effort: failures are logged but never raised — this runs on every
  # authenticated request and must not break page loads.
  #
  # @param tenant_user [TenantUser, nil]
  # @return [void]
  def auto_link_person(tenant_user)
    tenant_user&.ensure_person!
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.warn(
      "ensure_person! failed for TenantUser #{tenant_user&.id}: #{e.message}"
    )
  end

  # Resolves the current tenant for the request.
  #
  # Tries the tenant stored in session first (set on login or via tenant switch).
  # Falls back to auto-setting when the user belongs to exactly one tenant.
  # Sets nothing for global admins with no tenant memberships.
  def set_tenant
    return unless current_user

    # Use without_tenant to bypass any existing scope — we are determining
    # which tenant to activate, so we must query unconditionally.
    tenant = ActsAsTenant.without_tenant do
      host_tenant_for_member ||
        if session[:current_tenant_id]
          current_user.tenants.find_by(id: session[:current_tenant_id])
        else
          t = current_user.tenants.first
          if t
            session[:current_tenant_id] = t.id
            t
          end
        end
    end

    set_current_tenant(tenant) if tenant
  end

  # The tenant whose custom domain this request arrived on (#660), or nil.
  # Memoised per request; available pre-auth (the sign-in page brands by it).
  # The canonical host can never be a tenant's, so it skips the lookup.
  def host_tenant
    return @host_tenant if defined?(@host_tenant)

    canonical = Rails.application.config.action_mailer.default_url_options&.dig(:host)
    @host_tenant = request.host == canonical ? nil : Tenant.for_host(request.host)
  end

  # A request on a tenant's custom domain assumes that tenant for its members
  # (#660) — the host wins over the session, as on any workspace URL. A signed-in
  # non-member falls through to the usual resolution.
  def host_tenant_for_member
    tenant = host_tenant
    return nil unless tenant && current_user.tenants.exists?(tenant.id)

    session[:current_tenant_id] = tenant.id
    tenant
  end

  # The tenant a sign-on surface should assume, shared by the password and
  # SSO flows so they cannot drift: the host's custom domain (#660) first,
  # then an explicit slug, then the instance's default tenant
  # (https://github.com/espaliahq/espalia/issues/12) — the default only when
  # no slug was asked for at all, so a mistyped or empty slug never silently
  # wears the default's identity.
  #
  # @param slug_param [String, nil] the raw tenant_slug the surface carried
  # @return [Tenant, nil]
  def sign_on_tenant(slug_param)
    return host_tenant if host_tenant

    if slug_param.nil?
      Tenant.default_sign_in_tenant
    elsif slug_param.is_a?(String) && slug_param.present?
      ActsAsTenant.without_tenant { Tenant.find_by(slug: slug_param) }
    end
  end

  # Points the session at the tenant a sign-on surface promised (#660) —
  # only for members; anyone else keeps the usual resolution.
  def pin_session_to_tenant(user, tenant)
    return unless tenant && ActsAsTenant.without_tenant { user.tenants.exists?(tenant.id) }

    session[:current_tenant_id] = tenant.id
  end

  # Tags every event published during this web request with provenance via
  # {AuditMetadata}: `acting_via: :web`, the acting Person's `actor_id`, and
  # a `correlation_id` (the Rails request id) shared by every event this
  # request produces. When an impersonation session is active, `actor_id` is
  # the impersonated target (the write reads as theirs) and `impersonator_id`
  # names the real admin — see {Impersonatable}. Operations and grandfathered
  # controllers that publish events inherit it through the thread-local
  # without any per-handler wiring. The `ensure` guarantees cleanup even on
  # raised exceptions — an `after_action` would skip on raises and could leak
  # context into the next request on the same Puma worker thread.
  def wrap_with_audit_metadata
    AuditMetadata.seed!(
      acting_via: :web,
      actor_id: current_person&.id,
      impersonator_id: impersonating? ? real_context.person&.id : nil,
      impersonation_active: impersonating?,
      correlation_id: request.request_id
    )
    yield
  ensure
    AuditMetadata.clear!
  end

  # Directs users to the right place after sign-in based on tenant membership.
  #
  # Always auto-selects the first tenant. Multi-tenant users can switch
  # tenants via the user menu dropdown in the navbar.
  #
  # Honours a stored return-to location (`session[:user_return_to]`) so a
  # deep link that bounced through sign-in — most notably the MCP OAuth
  # `/oauth/authorize` flow, whose `resource_owner_authenticator` stashes
  # the original URL before redirecting an anonymous user to sign-in — lands
  # back on its target instead of the home page. Falls back to `root_path`.
  #
  # @param resource [User]
  # @return [String] redirect path
  def after_sign_in_path_for(resource)
    # Use without_tenant — no tenant is set yet at sign-in time.
    first_membership = ActsAsTenant.without_tenant { resource.tenant_users.first }
    session[:current_tenant_id] = first_membership.tenant_id if first_membership
    stored_location_for(resource) || root_path
  end
end
