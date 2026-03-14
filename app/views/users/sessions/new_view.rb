# frozen_string_literal: true

# Phlex view for the Devise sign-in page.
#
# Renders a full-page centered auth layout with GrowthOS branding,
# styled form fields, flash error display, and helper links.
class Views::Users::Sessions::NewView < Views::Base
  include Phlex::Rails::Helpers::Routes

  # @param resource [User] the Devise resource (an unsaved User instance)
  # @param flash [ActionDispatch::Flash::FlashHash] the current request flash
  def initialize(resource:, flash:)
    @resource = resource
    @flash = flash
  end

  def view_template
    div(class: "min-h-screen bg-primary flex items-center justify-center p-4") do
      div(class: "w-full max-w-sm") do
        branding
        auth_card
      end
    end
  end

  private

  def branding
    div(class: "text-center mb-8") do
      h1(class: "text-3xl font-bold text-white tracking-tight") { "GrowthOS" }
      p(class: "text-white/70 mt-1 text-sm") { "Career growth for your team" }
    end
  end

  def auth_card
    div(class: "bg-white rounded-2xl shadow-xl p-8") do
      h2(class: "text-lg font-semibold text-gray-900 mb-6") { "Sign in to your account" }
      flash_alert
      sign_in_form
      footer_links
    end
  end

  def flash_alert
    return unless @flash[:alert]

    div(
      class: "mb-5 flex items-start gap-2.5 rounded-lg border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-700",
      role: "alert"
    ) do
      span(class: "mt-0.5 shrink-0", aria: { hidden: "true" }) { "⚠" }
      span { @flash[:alert] }
    end
  end

  def sign_in_form
    form(
      action: user_session_path,
      method: :post,
      class: "space-y-4"
    ) do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)

      form_field("Email", :email, "user[email]", type: :email, autocomplete: "email")
      form_field("Password", :password, "user[password]", type: :password, autocomplete: "current-password")
      remember_me_field
      submit_button
    end
  end

  def form_field(label_text, id, name, type:, autocomplete: nil)
    div do
      label(for: "user_#{id}", class: "block text-sm font-medium text-gray-700 mb-1") { label_text }
      input(
        id: "user_#{id}",
        name: name,
        type: type,
        autocomplete: autocomplete,
        required: true,
        class: "block w-full rounded-lg border border-gray-300 px-3 py-2 text-sm text-gray-900 placeholder-gray-400 focus:border-primary focus:outline-none focus:ring-2 focus:ring-primary/20"
      )
    end
  end

  def remember_me_field
    div(class: "flex items-center gap-2") do
      input(
        id: "user_remember_me",
        name: "user[remember_me]",
        type: "checkbox",
        value: "1",
        class: "h-4 w-4 rounded border-gray-300 text-primary focus:ring-primary/20"
      )
      label(for: "user_remember_me", class: "text-sm text-gray-600") { "Remember me" }
    end
  end

  def submit_button
    button(
      type: "submit",
      class: "w-full rounded-lg bg-primary px-4 py-2.5 text-sm font-semibold text-white hover:bg-secondary focus:outline-none focus:ring-2 focus:ring-primary/50 focus:ring-offset-2 transition-colors"
    ) { "Log in" }
  end

  def footer_links
    div(class: "mt-6 space-y-2 text-center text-sm") do
      div do
        a(href: new_user_registration_path, class: "text-primary hover:text-secondary font-medium") { "Create an account" }
      end
      div do
        a(href: new_user_password_path, class: "text-gray-500 hover:text-gray-700") { "Forgot your password?" }
      end
    end
  end
end
