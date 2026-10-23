# frozen_string_literal: true

# @label Colour roles
class DesignTokens::RolesPreview < Lookbook::Preview
  STYLESHEET = Rails.root.join("app/assets/tailwind/theme/roles.css")
  TONES = %w[neutral brand accent danger success warning info nav].freeze
  GROUPS = [ "Content", "Surfaces", "Borders", *TONES.map(&:capitalize) ].freeze
  SURFACES = %w[--gos-surface-default --gos-surface-page].freeze
  UTILITY_PREFIXES = { "text" => "text", "background" => "bg", "border" => "border", "ring" => "ring", "outline" => "outline" }.freeze

  # Brand inputs for the helper: adversarial fills, the tie mid-tone, and greys either side of the tie.
  HELPER_FILLS = [
    [ "Default teal", "#32c8c8" ], [ "Default teal, light", "#5ee0e0" ],
    [ "me&u", "#00362F" ], [ "me&u, light", "#5ee0a0" ],
    [ "Testco", "#6366f1" ], [ "Lime", "#dbfc45" ], [ "Yellow", "#facc15" ], [ "Pink", "#ec4899" ],
    [ "Tie mid-tone", "#c2541e" ], [ "Grey below the tie", "#757575" ], [ "Grey above the tie", "#767676" ]
  ].freeze

  # Every --gos-* role in roles.css, with its utilities, value and contrast checks.
  def roles
    render_with_template(locals: { groups: grouped_roles })
  end

  # The text colour helper on brand fills a tenant could pick, by both paths.
  def contrast_helper
    render_with_template(locals: { fills: HELPER_FILLS, fallback: helper_fallback })
  end

  private

  def stylesheet
    STYLESHEET.read
  end

  # The fallback declaration as roles.css writes it, so the proof can't drift from the formula it proves.
  def helper_fallback
    stylesheet[/@supports \(color: color\(from red srgb-linear r g b\)\) \{\s*(--gos-brand-content-inverse:.*?;)/m, 1] ||
      raise("roles.css no longer has the contrast helper's relative-colour fallback")
  end

  def grouped_roles
    names = stylesheet.scan(/^\s*(--gos-[\w-]+):/).flatten.uniq.reject { |name| name.start_with?("--gos-tone-") }
    names.map { |name| { name: name, utilities: utilities[name] || [], checks: checks(name) } }
         .group_by { |role| group(role[:name]) }
         .sort_by { |group, _| GROUPS.index(group) || GROUPS.size }
  end

  # `--text-color-muted: var(--gos-content-muted)` in @theme inline gives text-muted.
  def utilities
    @utilities ||= stylesheet.scan(/--(#{UTILITY_PREFIXES.keys.join("|")})-color-([\w-]+):\s*var\((--gos-[\w-]+)\)/)
                             .each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |(property, name, role), map|
      map[role] << "#{UTILITY_PREFIXES[property]}-#{name}"
    end
  end

  def group(name)
    tone = name[/\A--gos-(?:content-|border-)?(#{TONES.join("|")})(?:-|\z)/, 1]
    return tone.capitalize if tone
    return "Content" if name.start_with?("--gos-content-")
    return "Borders" if name.start_with?("--gos-border-") || name == "--gos-focus-ring"

    "Surfaces"
  end

  # [text, fill, minimum ratio] pairs: content on the page surfaces, fills with the text that sits on them.
  def checks(name)
    case name
    when "--gos-content-inverse" then [ [ name, "--gos-surface-inverse", 4.5 ] ]
    when /\A--gos-\w+-content-inverse\z/ then []
    # Decorative glyphs and disabled controls, which WCAG doesn't hold to 4.5:1
    when "--gos-content-subtle", "--gos-content-disabled" then []
    when /\A--gos-content-/ then SURFACES.map { |surface| [ name, surface, 4.5 ] }
    when /\A--gos-border-/, "--gos-focus-ring" then SURFACES.map { |surface| [ name, surface, 3 ] }
    when "--gos-surface-inverse" then [ [ "--gos-content-inverse", name, 4.5 ] ]
    when "--gos-nav-surface" then [ [ "--gos-nav-content", name, 4.5 ] ]
    when /\A--gos-surface-/ then []
    when /\A--gos-(\w+)-strong(-hover)?\z/ then [ [ "--gos-#{$1}-content-inverse", name, 4.5 ] ]
    when /\A--gos-neutral-(subtle|muted)\z/ then [ [ "--gos-content-default", name, 4.5 ] ]
    when /\A--gos-(\w+)-(subtle|muted)\z/ then [ [ "--gos-content-#{$1}", name, 4.5 ] ]
    else []
    end
  end
end
