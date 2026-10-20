# frozen_string_literal: true

# @label Elevation and radius
class DesignTokens::ElevationPreview < Lookbook::Preview
  STYLESHEET = Rails.root.join("app/assets/tailwind/theme/roles.css")
  SOURCES = %w[app/components/**/*.rb app/views/**/*.rb app/javascript/**/*.js].freeze

  # Literal class names so Tailwind's scanner emits them.
  LEVELS = {
    "shadow-raised" => "A card on the page",
    "shadow-overlay" => "Menus, popovers, tooltips, toasts and the mobile drawers",
    "shadow-modal" => "A modal dialog"
  }.freeze
  RADII = %w[rounded-sm rounded-md rounded-lg rounded-2xl rounded-full].freeze

  # Each elevation role on the page and on a card, with its value under the current theme and scheme.
  def elevation
    levels = LEVELS.map do |utility, job|
      role = "--gos-#{utility}"
      { utility: utility, job: job, role: role, declared: declared(role), used_by: used_by(SOURCES, utility) }
    end
    render_with_template(locals: { levels: levels })
  end

  # The radius steps, each with the Kit components that own it.
  def radius
    radii = RADII.map { |step| { step: step, used_by: used_by(%w[app/components/kit/*.rb], step) } }
    render_with_template(locals: { radii: radii })
  end

  private

  def declared(role)
    STYLESHEET.read[/^\s*#{role}:\s*(.*?);/, 1] || raise("roles.css no longer defines #{role}")
  end

  # Source files that use the class, by path under app/ (comments skipped)
  def used_by(globs, utility)
    pattern = /(?<![\w-])#{Regexp.escape(utility)}(?![\w-])/
    globs.flat_map { |glob| Dir[Rails.root.join(glob)] }.select do |path|
      File.readlines(path).any? { |line| !line.lstrip.start_with?("#", "//") && line.match?(pattern) }
    end.map { |path| path.delete_prefix("#{Rails.root.join("app")}/").sub(/\.(rb|js)\z/, "") }.sort
  end
end
