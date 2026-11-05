# frozen_string_literal: true

# Phlex view for the Devise sign-in page.
#
# Renders a full-page centered auth layout with GrowthOS branding,
# styled form fields, flash error display, and helper links.
class Views::Users::Sessions::NewView < Views::Base
  include Phlex::Rails::Helpers::Routes
  include Phlex::Rails::Helpers::ContentFor

  BROWSER_THEME_COLOR = "#6b58da"

  # Copies of STEPS and LEAF in bin/build-icons; test/integration/app_icons_test.rb keeps them equal.
  MARK_PATHS = [
    "M223,847 H777 A28,28 0 0 0 805,819 V408 A28,28 0 0 0 777,380 H633 A28,28 0 0 0 605,408 V506 " \
    "A14,14 0 0 1 591,520 H428 A28,28 0 0 0 400,548 V636 A14,14 0 0 1 386,650 H223 A28,28 0 0 0 " \
    "195,678 V819 A28,28 0 0 0 223,847 Z",
    "M688,400 V330 C688,235 765,180 868,180 C870,300 812,380 726,380 V400 Z"
  ].freeze

  BUTTON_CLASSES = "inline-flex w-full items-center justify-center gap-2 h-11 px-4 rounded-lg " \
                   "text-sm/5 font-semibold cursor-pointer transition-colors duration-200"

  # @param resource [User] the Devise resource (an unsaved User instance)
  # @param flash [ActionDispatch::Flash::FlashHash] the current request flash
  # @param google_sso [Boolean] whether to offer "Continue with Google"
  # @param tenant [Tenant, nil] the tenant whose sign-on URL this is (#660);
  #   its name heads the page and the layout carries its theme
  def initialize(resource:, flash:, google_sso: true, tenant: nil)
    @resource = resource
    @flash = flash
    @google_sso = google_sso
    @tenant = tenant
  end

  def view_template
    if @tenant.nil?
      # Tenant-less sign-in names its own look; a tenant page takes the
      # tenant's theme through the layout (@theme_tenant) instead.
      content_for(:html_theme, "bento")
      content_for(:theme_color, view_context.tag.meta(name: "theme-color", content: BROWSER_THEME_COLOR))
    end

    main(id: "main-content", class: "auth-page relative isolate overflow-hidden min-h-dvh flex items-center justify-center p-4 " \
                "bg-default text-default antialiased") do
      backdrop
      div(class: "w-full max-w-100 flex flex-col gap-6") do
        branding
        auth_card
      end
    end
  end

  private

  def backdrop
    blob = "auth-blob#{" auth-blob-brand" if @tenant}"
    span(class: "#{blob} size-[420px] left-[30%] top-[30%] sm:size-[56vmax] sm:left-[36%] sm:top-[34%]",
      aria: { hidden: "true" })
    span(class: "#{blob} size-[400px] left-[74%] top-1/2 sm:size-[52vmax] sm:left-[64%] sm:top-[46%]",
      aria: { hidden: "true" })
    span(class: "#{blob} size-[380px] left-[44%] top-[76%] sm:size-[50vmax] sm:left-1/2",
      aria: { hidden: "true" })
  end

  def branding
    div(class: "flex flex-col items-center gap-3 text-center") do
      brand_mark
      h1(class: "text-2xl/7 font-bold") { @tenant ? @tenant.name : product_name }
      p(class: "text-base/5 text-muted") do
        @tenant ? "#{@tenant.product_name} · Career growth for your team" : "Career growth for your team"
      end
    end
  end

  def brand_mark
    svg(class: "size-10#{" text-brand" if @tenant}", viewBox: "166.5 148.5 730 730", aria: { hidden: "true" }, focusable: "false",
      data: { brand_mark: true }) do |s|
      s.g(fill: "currentColor") do
        MARK_PATHS.each { |d| s.path(d:) }
      end
    end
  end

  def auth_card
    section(
      class: "flex flex-col gap-5 p-4 sm:p-6 rounded-lg border border-subtle " \
             "bg-default/78 backdrop-blur-[24px] backdrop-saturate-[1.2]",
      aria: { labelledby: "sign-in-title" }
    ) do
      h2(id: "sign-in-title", class: "text-lg/5 font-bold") { "Sign in to your account" }
      flash_alert
      if @google_sso
        google_button
        divider
      end
      sign_in_form
      footer_links
    end
  end

  def google_button
    # The slug rides the QUERY string: OmniAuth copies request.GET (never the
    # form body) into omniauth.params for the callback to scope by (#660).
    authorize_path = @tenant ? user_google_oauth2_omniauth_authorize_path(tenant_slug: @tenant.slug) : user_google_oauth2_omniauth_authorize_path
    form(
      action: authorize_path,
      method: :post,
      data: { turbo: "false" }
    ) do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      button(
        type: "submit",
        class: "#{BUTTON_CLASSES} bg-neutral-subtle hover:bg-neutral-muted text-default"
      ) do
        google_logo
        span { "Continue with Google" }
      end
    end
  end

  def google_logo
    svg(class: "size-5 shrink-0", viewBox: "0 0 48 48", aria: { hidden: "true" }) do |s|
      s.path(fill: "#FFC107", d: "M43.6 20.5H42V20H24v8h11.3c-1.6 4.7-6.1 8-11.3 8-6.6 0-12-5.4-12-12s5.4-12 12-12c3 0 5.8 1.1 7.9 3l5.7-5.7C34 6.1 29.3 4 24 4 12.9 4 4 12.9 4 24s8.9 20 20 20 20-8.9 20-20c0-1.2-.1-2.4-.4-3.5z")
      s.path(fill: "#FF3D00", d: "M6.3 14.7l6.6 4.8C14.7 16 19 13 24 13c3 0 5.8 1.1 7.9 3l5.7-5.7C34 6.1 29.3 4 24 4 16.3 4 9.7 8.4 6.3 14.7z")
      s.path(fill: "#4CAF50", d: "M24 44c5.2 0 9.9-2 13.4-5.2l-6.2-5.2c-2 1.4-4.5 2.4-7.2 2.4-5.2 0-9.6-3.3-11.3-8l-6.5 5C9.6 39.6 16.2 44 24 44z")
      s.path(fill: "#1976D2", d: "M43.6 20.5H42V20H24v8h11.3c-.8 2.3-2.3 4.3-4.1 5.6l6.2 5.2C40.9 36 44 30.5 44 24c0-1.2-.1-2.4-.4-3.5z")
    end
  end

  def divider
    div(
      id: "sign-in-divider",
      class: "flex items-center gap-3 text-xs/[14px] font-semibold uppercase tracking-[.04em] " \
             "text-muted before:flex-1 before:border-t before:border-default dark:before:border-subtle " \
             "after:flex-1 after:border-t after:border-default dark:after:border-subtle",
      aria: { hidden: "true" }
    ) { "or" }
  end

  def flash_alert
    return unless @flash[:alert]

    div(
      class: "flex items-start gap-2 p-3 rounded-lg border border-danger bg-danger-subtle " \
             "text-sm/[18px] text-danger",
      role: "alert"
    ) do
      alert_icon
      span { @flash[:alert] }
    end
  end

  def alert_icon
    svg(
      class: "size-4 shrink-0 mt-px", viewBox: "0 0 24 24", aria: { hidden: "true" },
      fill: "none", stroke: "currentColor", stroke_width: "2", stroke_linecap: "round", stroke_linejoin: "round"
    ) do |s|
      s.circle(cx: "12", cy: "12", r: "9")
      s.path(d: "M12 7.5v5")
      s.path(d: "M12 16.5h.01")
    end
  end

  def sign_in_form
    form(
      action: user_session_path,
      method: :post,
      class: "flex flex-col gap-4"
    ) do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      input(type: "hidden", name: "tenant_slug", value: @tenant.slug) if @tenant

      form_field("Email", :email, "user[email]", type: :email, autocomplete: "email")
      form_field("Password", :password, "user[password]", type: :password, autocomplete: "current-password")
      remember_me_field
      submit_button
    end
  end

  def form_field(label_text, id, name, type:, autocomplete: nil)
    div(class: "flex flex-col gap-1.5") do
      label(for: "user_#{id}", class: "text-sm/5 font-semibold") { label_text }
      input(
        id: "user_#{id}",
        name: name,
        type: type,
        autocomplete: autocomplete,
        required: true,
        class: "w-full h-11 px-3 rounded-lg border border-field " \
               "bg-field text-sm/[18px] text-default"
      )
    end
  end

  def remember_me_field
    label(for: "user_remember_me", class: "flex items-center gap-2 min-h-11 text-sm/[18px]") do
      input(
        id: "user_remember_me",
        name: "user[remember_me]",
        type: "checkbox",
        value: "1",
        class: "auth-check"
      )
      plain "Remember me"
    end
  end

  def submit_button
    # A tenant page shows the tenant's brand; the generic page stays neutral.
    # The tone pair keeps the text readable on whatever colour the tenant picked.
    tone = @tenant ? "tone-brand" : "tone-neutral"
    button(
      type: "submit",
      class: "#{BUTTON_CLASSES} #{tone} bg-tone-strong hover:bg-tone-strong-hover " \
             "text-tone-content-inverse"
    ) { "Log in" }
  end

  def footer_links
    div(class: "flex flex-col items-center text-center text-sm/[18px]") do
      a(
        href: new_user_registration_path,
        class: "inline-flex items-center min-h-11 text-sm/5 font-semibold underline underline-offset-3 " \
               "decoration-(--gos-border-default) hover:decoration-current transition-colors duration-200"
      ) { "Create an account" }
      a(
        href: new_user_password_path,
        class: "inline-flex items-center min-h-11 text-muted hover:underline underline-offset-3"
      ) { "Forgot your password?" }
    end
  end
end
