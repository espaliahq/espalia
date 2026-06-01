# frozen_string_literal: true

# Sticky banner shown on every page while a tenant admin is impersonating
# another user ("view as"). Makes the read-only impersonation state
# impossible to miss and offers a one-click exit.
#
# Rendered from the application layout when {Impersonatable#impersonating?}
# is true; the layout passes the target's display name.
#
# @example
#   render Components::Kit::ImpersonationBanner.new(name: "Alex Chen")
class Components::Kit::ImpersonationBanner < Components::Base
  # @param name [String] display name of the impersonated user
  def initialize(name:)
    @name = name
  end

  def view_template
    div(
      class: "sticky top-0 z-[70] flex items-center justify-center gap-x-3 gap-y-1 flex-wrap " \
             "bg-amber-500 px-4 py-2 text-sm font-medium text-amber-950 shadow-sm",
      role: "status"
    ) do
      eye_icon
      span do
        plain "Viewing as "
        span(class: "font-semibold") { @name }
        span(class: "font-normal opacity-80") { " — read-only" }
      end
      stop_button
    end
  end

  private

  def stop_button
    form(action: impersonation_path, method: "post", class: "contents") do
      input(type: "hidden", name: "_method", value: "delete")
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      button(
        type: "submit",
        class: "rounded-md bg-amber-950/10 px-2.5 py-0.5 text-xs font-semibold text-amber-950 " \
               "hover:bg-amber-950/20 focus:outline-hidden focus:ring-2 focus:ring-amber-950/40 cursor-pointer"
      ) { "Stop impersonating" }
    end
  end

  def eye_icon
    svg(
      xmlns: "http://www.w3.org/2000/svg",
      class: "h-4 w-4 shrink-0",
      fill: "none",
      viewBox: "0 0 24 24",
      stroke: "currentColor",
      stroke_width: "2",
      aria_hidden: "true"
    ) do |s|
      s.path(stroke_linecap: "round", stroke_linejoin: "round",
             d: "M15 12a3 3 0 11-6 0 3 3 0 016 0z")
      s.path(stroke_linecap: "round", stroke_linejoin: "round",
             d: "M2.458 12C3.732 7.943 7.523 5 12 5c4.478 0 8.268 2.943 9.542 7-1.274 4.057-5.064 7-9.542 7-4.477 0-8.268-2.943-9.542-7z")
    end
  end
end
