#!/usr/bin/env ruby
# frozen_string_literal: true

# Script to parse me&u career framework spreadsheets into a single YAML file.
#
# Usage:
#   ruby scripts/parse_career_framework.rb
#
# Input:
#   - tmp/Unified Product - 2025 Career Path Framework.xlsx
#   - tmp/Finance - 2025 Career Framework.xlsx
#
# Output:
#   - db/seeds/meandu_career_framework.yml

require "roo"
require "yaml"

# ---------------------------------------------------------------------------
# HTML / text helpers
# ---------------------------------------------------------------------------

def clean_text(text)
  return "" if text.nil?
  text.to_s
    .gsub(/<\/?[^>]+>/, "")
    .gsub(/\r\n/, "\n")
    .gsub(/\n{3,}/, "\n\n")
    .strip
end

# Clean a capability/category name: collapse newlines to spaces, fix known typos
def clean_name(text)
  return "" if text.nil?
  result = text.gsub(/\n+/, " ").gsub(/\s+/, " ").strip
  # Fix known typos from spreadsheet data
  result = result.sub(/\bPlanning & Deliver\b/, "Planning & Delivery")
  result
end

# Clean a role scope string like "Analytics Engineer\n+\nData Engineer"
# into a sorted array like ["Analytics Engineer", "Data Engineer"]
def normalize_role_scope(text)
  return [] if text.nil? || text.strip.empty?
  text.split(/\n*\+\n*|\s*,\s*/)
    .map(&:strip)
    .reject(&:empty?)
    .sort
end

# Normalize text for dedup comparison: em-dash vs hyphen, whitespace
def normalize_for_dedup(text)
  return "" if text.nil?
  text.gsub("\u2014", "-")  # em-dash to hyphen
    .gsub("\u2013", "-")     # en-dash to hyphen
    .gsub(/\s+/, " ")
    .strip
    .downcase
end

# Extract bold segments from HTML. Returns array of bold text segments.
def extract_bold_segments(html)
  return [] if html.nil?
  segments = []
  remaining = html.to_s.gsub(/<\/?html>/, "")
  while remaining =~ /<b>(.*?)<\/b>/m
    segments << clean_text($1)
    remaining = $~.post_match
  end
  segments.reject(&:empty?)
end

# Extract non-bold text from HTML (everything outside <b> tags, excluding <i> and <html>)
def extract_non_bold_text(html)
  return nil if html.nil?
  text = html.to_s.gsub(/<\/?html>/, "")
  # Remove italic tags but keep content
  text = text.gsub(/<\/?i>/, "")
  # Remove bold segments entirely
  text = text.gsub(/<b>.*?<\/b>/m, "")
  cleaned = clean_text(text)
  cleaned.empty? ? nil : cleaned
end

# Extract name and description from a capability/category cell.
# First bold segment = name, remaining bold + italic = description.
def extract_name_and_description(html)
  return [ nil, nil ] if html.nil? || html.to_s.strip.empty?

  bold_segments = extract_bold_segments(html)

  if bold_segments.empty?
    # No bold — use entire text as name
    return [ clean_text(html), nil ]
  end

  name = bold_segments.first

  # Description: remaining bold segments + non-bold text. The non-bold text
  # already includes italic content, so reading italics separately as well
  # stored those sentences twice (#333).
  desc_parts = []
  desc_parts.concat(bold_segments[1..]) if bold_segments.length > 1

  non_bold = extract_non_bold_text(html)
  desc_parts << non_bold if non_bold

  description = desc_parts.reject(&:empty?).join("\n")
  description = nil if description.empty?

  [ clean_name(name), description ]
end

# All known role code patterns across all sheets (for parsing illustrations)
ALL_ROLE_CODES = %w[
  E1 E2 E3 E4 E5 E6 E7 E8
  EM3 EM4 EM5 EM6 EM7 EM8
  AE1 AE2 AE3
  DE1 DE2 DE3 DE4 DE5 DE6 DE7 DE8
  DM3 DM4 DM5 DM6 DM7 DM8
  PM1 PM2 PM3 PM4 PM5 PM6 PM7 PM8
  PD1 PD2 PD3 PD4 PD5 PD6 PD7 PD8
  FC1 FC2 FC3 FC4 FC5 FC6 FC7 FC8
  FCo1 FCo2 FCo3 FCo4 FCo5 FCo6 FCo7 FCo8
  CF1 CF2 CF3 CF4 CF5 CF6 CF7 CF8
  FO1 FO2 FO3 FO4 FO5 FO6 FO7 FO8
].freeze

# Default role code(s) to assign to illustrations that have no role-code prefix,
# based on which spreadsheet sheet they came from.
SHEET_DEFAULT_ROLE_CODES = {
  "Data" => nil,                              # Data sheets usually have AE/DE/DM prefixes; fallback handled below
  "Software Engineering" => nil,              # Usually have E/EM prefixes; fallback handled below
  "Product Design" => %w[PD],
  "Product Management" => %w[PM],
  "Financial Control" => %w[FC FCo],
  "Commercial Finance" => %w[CF],
  "Finance Operations" => %w[FO],
  "Core 11 and Leadership Capabili" => :discard  # Discard unprefixed illustrations (generic reference text)
}.freeze

# Fallback defaults for Data and Software Engineering sheets (all role codes in that family)
SHEET_FALLBACK_ROLE_CODES = {
  "Data" => %w[AE DE DM],
  "Software Engineering" => %w[E EM]
}.freeze

def build_role_code_pattern(known_role_codes)
  return nil if known_role_codes.empty?
  escaped = known_role_codes.sort_by { |c| -c.length }.map { |c| Regexp.escape(c) }
  "((?:#{escaped.join('|')})(?:/(?:#{escaped.join('|')}))*)"
end

# Extract role-code prefixed illustrations from text.
# Text like "E3: Does X\n\nEM3: Does Y" => [{role_code: "E3", description: "Does X"}, ...]
# Text without role codes => [{description: "the whole text"}]
# When sheet_name is provided, unprefixed illustrations get assigned default role codes.
def extract_role_illustrations(text, known_role_codes, sheet_name: nil)
  return [] if text.nil? || text.strip.empty?

  code_pattern = build_role_code_pattern(known_role_codes)
  code_pattern ||= "([A-Z]{1,3}\\d+)"

  segments = text.split(/(?:^|\n)\s*#{code_pattern}\s*:\s*/i)

  illustrations = []
  if segments.length > 1
    i = 1
    while i < segments.length - 1
      codes = segments[i].strip
      desc = clean_text(segments[i + 1])
      unless desc.empty?
        codes.split("/").each do |code|
          code = code.strip
          illustrations << { "role_code" => code, "description" => desc }
        end
      end
      i += 2
    end
  end

  if illustrations.empty? && !text.strip.empty?
    cleaned = clean_text(text)
    illustrations << { "description" => cleaned } unless cleaned.empty?
  end

  # Assign default role codes to illustrations missing one, based on sheet
  assign_default_role_codes!(illustrations, sheet_name) if sheet_name

  illustrations
end

# Assign default role codes to illustrations that have no role_code, based on sheet origin.
def assign_default_role_codes!(illustrations, sheet_name)
  default = SHEET_DEFAULT_ROLE_CODES[sheet_name]
  fallback = SHEET_FALLBACK_ROLE_CODES[sheet_name]

  illustrations.reject! do |ill|
    next false if ill["role_code"] && !ill["role_code"].to_s.strip.empty?

    # This illustration has no role_code
    if default == :discard
      true # Remove it
    elsif default.is_a?(Array) && default.any?
      # Expand into one illustration per default role code
      false # Will be handled below
    elsif fallback.is_a?(Array) && fallback.any?
      false # Will be handled below
    else
      false # Keep as-is (shouldn't happen with proper config)
    end
  end

  # Now expand illustrations with no role_code into per-role-code copies
  expanded = []
  illustrations.each do |ill|
    if ill["role_code"] && !ill["role_code"].to_s.strip.empty?
      expanded << ill
    else
      codes = if default.is_a?(Array) && default.any?
                default
      elsif fallback.is_a?(Array) && fallback.any?
                fallback
      else
                [ nil ] # Keep without role_code (shouldn't happen)
      end
      codes.each do |code|
        new_ill = ill.dup
        new_ill["role_code"] = code if code
        expanded << new_ill
      end
    end
  end

  illustrations.replace(expanded)
end

# Split bold text that contains embedded role code illustrations.
# E.g. "Makes well-reasoned choices.\n\nE5: Frames ambiguous problems..."
# Returns [canonical_text, [illustrations]]
def split_canonical_and_role_illustrations(text, known_role_codes, sheet_name: nil)
  return [ text, [] ] if known_role_codes.empty?

  code_pattern = build_role_code_pattern(known_role_codes)
  return [ text, [] ] unless code_pattern

  parts = text.split(/\n+/)
  canonical_parts = []
  illustration_text = []
  found_role = false

  parts.each do |part|
    stripped = part.strip
    next if stripped.empty?
    if !found_role && stripped.match?(/\A#{code_pattern}\s*:/i)
      found_role = true
    end
    if found_role
      illustration_text << stripped
    else
      canonical_parts << stripped
    end
  end

  if canonical_parts.empty? && !illustration_text.empty?
    canonical_parts = [ illustration_text.shift ]
  end

  canonical = canonical_parts.join(" ")
  illustrations = extract_role_illustrations(illustration_text.join("\n"), known_role_codes, sheet_name: sheet_name)

  [ canonical, illustrations ]
end

# Parse an expectation cell: extract canonical expectation (bold) and illustrations.
def parse_expectation_cell(html, known_role_codes = [], sheet_name: nil)
  return [ nil, [] ] if html.nil? || html.to_s.strip.empty?

  bold_segments = extract_bold_segments(html)
  non_bold = extract_non_bold_text(html)

  # If no bold at all, entire text is the canonical expectation
  if bold_segments.empty?
    plain = clean_text(html)
    return [ plain, [] ] unless plain.empty?
    return [ nil, [] ]
  end

  illustrations = []

  # First bold segment is the canonical expectation.
  # It might contain role-code prefixed illustrations after the canonical text.
  first_bold = bold_segments.first
  canonical, first_bold_ills = split_canonical_and_role_illustrations(first_bold, known_role_codes, sheet_name: sheet_name)
  illustrations.concat(first_bold_ills)

  # Subsequent bold segments: check if they contain role-code prefixed illustrations.
  # If not, treat each as a standalone illustration.
  bold_segments[1..]&.each do |seg|
    _seg_canonical, seg_ills = split_canonical_and_role_illustrations(seg, known_role_codes, sheet_name: sheet_name)
    if seg_ills.any?
      illustrations.concat(seg_ills)
    else
      # No role codes — this bold segment is an illustration without a role code
      illustrations << { "description" => seg } unless seg.strip.empty?
    end
  end

  # Parse non-bold text for role-code prefixed illustrations
  if non_bold && !non_bold.empty?
    role_ills = extract_role_illustrations(non_bold, known_role_codes, sheet_name: sheet_name)
    illustrations.concat(role_ills)
  end

  # Final pass: assign default role codes to any remaining illustrations without one
  assign_default_role_codes!(illustrations, sheet_name) if sheet_name

  [ canonical, illustrations ]
end

# ---------------------------------------------------------------------------
# Merge illustrations when deduplicating shared capabilities
# ---------------------------------------------------------------------------

# Check whether two capabilities' canonical expectations differ substantially.
# Returns true only when a majority of shared levels have different descriptions,
# which indicates genuinely distinct capabilities (not minor wording variations).
def expectations_differ?(cap_a, cap_b)
  a_exps = cap_a["expectations"] || []
  b_exps = cap_b["expectations"] || []

  # Build level -> description maps
  a_by_level = a_exps.each_with_object({}) { |e, h| h[e["level"]] = e["description"] }
  b_by_level = b_exps.each_with_object({}) { |e, h| h[e["level"]] = e["description"] }

  shared_levels = a_by_level.keys & b_by_level.keys
  return false if shared_levels.empty?

  diff_count = shared_levels.count do |level|
    normalize_for_dedup(a_by_level[level]) != normalize_for_dedup(b_by_level[level])
  end

  # Require at least a third of shared levels to differ — this catches
  # genuinely distinct capabilities (e.g. 4/8 levels differ for Finance vs
  # Product Leadership) while tolerating minor wording variations (1/8).
  diff_count >= (shared_levels.size / 3.0).ceil
end

def merge_illustrations(existing, new_cap)
  existing["expectations"].each do |exp|
    new_exp = new_cap["expectations"].find { |e| e["level"] == exp["level"] }
    next unless new_exp

    existing_ills = exp["illustrations"] || []
    new_ills = new_exp["illustrations"] || []

    new_ills.each do |ill|
      already = existing_ills.any? do |e|
        normalize_for_dedup(e["description"]) == normalize_for_dedup(ill["description"]) &&
          e["role_code"] == ill["role_code"]
      end
      existing_ills << ill unless already
    end

    exp["illustrations"] = existing_ills unless existing_ills.empty?
  end

  new_cap["expectations"].each do |new_exp|
    unless existing["expectations"].any? { |e| e["level"] == new_exp["level"] }
      existing["expectations"] << new_exp
    end
  end
end

# ---------------------------------------------------------------------------
# Sheet parsing
# ---------------------------------------------------------------------------

RoleTrack = Struct.new(:code, :title, :level, :col, :track, keyword_init: true)

def extract_role_code_and_title(text, _level)
  cleaned = text.gsub(/<\/?[^>]+>/, "").strip

  if cleaned.match(/\A([A-Z]{1,3}\d+)\s*(.+)/m)
    code = $1.strip
    title = $2.strip.split("\n").first&.strip
    return [ code, title ]
  end

  title = cleaned.split("\n").first&.strip
  [ nil, title ]
end

def find_first_data_row(xlsx)
  (1..xlsx.last_row).each do |row|
    val = xlsx.cell(row, 1)
    return row if val.to_s.strip == "1" || val.to_s.strip == "1.0"
  end
  nil
end

# Map raw group text to a clean category name
def normalize_group_to_category(group_text, role_family)
  return "Role Specific" if group_text.nil? || group_text.empty?

  # Normalize common patterns
  case group_text
  when /Engineering Capabilities/i
    "Engineering Capabilities"
  when /Data Capabilities/i
    "Data Capabilities"
  when /Role [Ss]pecific/i
    "Role Specific"
  else
    group_text
  end
end

def determine_scope(group_text, _col_c, _known_codes, _config)
  return "core" if group_text&.include?("Would apply to any role at me&u")
  return "leadership" if group_text&.match?(/Would apply to anyone in a leadership role at me&u/i)
  return "stream_leadership" if group_text&.match?(/Would apply to anyone in a Stream leadership role/i)
  return "finance" if group_text&.match?(/Would apply to anyone in Finance at me&u/i)
  return "finance_leadership" if group_text&.match?(/Would apply to anyone in a Finance leadership role/i)

  if group_text&.match?(/Role [Ss]pecific/i) || group_text&.match?(/Engineering Capabilities/i) ||
     group_text&.match?(/Data Capabilities/i)
    return "role_specific"
  end

  "core"
end

def parse_sheet(xlsx, sheet_name, config)
  xlsx.default_sheet = sheet_name

  first_data_row = find_first_data_row(xlsx)
  return { roles: [], capabilities: [] } unless first_data_row

  # Parse headers
  role_tracks = []
  (config[:header_rows] || []).each_with_index do |row_num, row_idx|
    (5..12).each do |col|
      cell = xlsx.cell(row_num, col)
      next if cell.nil? || cell.to_s.strip.empty?

      level = col - 4
      code, title = extract_role_code_and_title(cell.to_s, level)
      track = config[:track_map] ? (config[:track_map][row_idx] || "ic") : (row_idx == 0 ? "ic" : "management")

      role_tracks << RoleTrack.new(code: code, title: title, level: level, col: col, track: track)
    end
  end

  known_codes = role_tracks.map(&:code).compact
  parse_codes = (known_codes + ALL_ROLE_CODES).uniq

  capabilities = []
  current_category_name = nil
  current_category_desc = nil
  current_group = nil
  current_role_scope = nil

  (first_data_row..xlsx.last_row).each do |row|
    col_b = xlsx.cell(row, 2)
    col_c = xlsx.cell(row, 3)
    col_d = xlsx.cell(row, 4)

    next if col_d.nil? || col_d.to_s.strip.empty?

    # Update group (scope indicator) if col B has content
    if col_b && !col_b.to_s.strip.empty?
      current_group = clean_text(col_b)
    end

    # Update category if col C has content
    if col_c && !col_c.to_s.strip.empty?
      col_c_text = col_c.to_s

      # Check if col C is a category (has bold/italic) or a role scope (plain text like "Software Engineer")
      bold_segs = extract_bold_segments(col_c_text)
      if bold_segs.any?
        # This is a category
        cat_name, cat_desc = extract_name_and_description(col_c_text)
        current_category_name = cat_name
        current_category_desc = cat_desc
        current_role_scope = nil
      else
        # This is a role scope indicator (e.g., "Analytics Engineer\n+\nData Engineer")
        roles = normalize_role_scope(clean_text(col_c_text))
        current_role_scope = roles.length == 1 ? roles.first : roles
      end
    end

    # Parse capability name and description
    cap_name, cap_desc = extract_name_and_description(col_d.to_s)
    next if cap_name.nil? || cap_name.empty?

    # Determine scope
    scope = determine_scope(current_group, col_c, known_codes, config)

    # Override category based on scope
    effective_category = current_category_name
    effective_category_desc = current_category_desc
    role_binding = nil

    case scope
    when "leadership"
      effective_category = "Leadership"
      effective_category_desc = "Capabilities expected of anyone in a leadership role."
    when "stream_leadership"
      effective_category = "Stream Leadership"
      effective_category_desc = "Capabilities expected of anyone in a stream leadership role."
    when "finance"
      effective_category = "Finance Core"
      effective_category_desc = "Capabilities expected of anyone in Finance."
    when "finance_leadership"
      effective_category = "Finance Leadership"
      effective_category_desc = "Capabilities expected of anyone in a Finance leadership role."
    when "role_specific"
      role_binding = current_role_scope || config[:role_family]
      # Normalize the group text into a clean category name
      raw_group = clean_name(current_group)
      effective_category = normalize_group_to_category(raw_group, config[:role_family])
      effective_category_desc = nil
    end

    # Parse expectations for each level
    expectations = []
    (5..12).each do |col|
      level = col - 4
      cell = xlsx.cell(row, col)
      next if cell.nil? || cell.to_s.strip.empty?

      canonical, illustrations = parse_expectation_cell(cell.to_s, parse_codes, sheet_name: sheet_name)
      next if canonical.nil? || canonical.empty?

      exp = { "level" => level, "description" => canonical }
      exp["illustrations"] = illustrations unless illustrations.empty?
      expectations << exp
    end

    capabilities << {
      "name" => cap_name,
      "description" => cap_desc,
      "category" => effective_category,
      "category_description" => effective_category_desc,
      "scope" => scope,
      "role_binding" => role_binding,
      "sheet" => sheet_name,
      "group" => current_group,
      "expectations" => expectations
    }
  end

  { roles: role_tracks, capabilities: capabilities }
end

# ---------------------------------------------------------------------------
# Build role families
# ---------------------------------------------------------------------------

def build_role_families(all_roles_by_family, product_xlsx, finance_xlsx)
  families = []

  all_roles_by_family.each do |family_name, data|
    config = data[:config]
    tracks = data[:tracks]
    roles = []

    if config[:assign_codes]
      if config[:role_code_prefixes].size == 1
        prefix, info = config[:role_code_prefixes].first
        levels = tracks.sort_by(&:level).map do |t|
          {
            "ordinal" => t.level,
            "title" => t.title,
            "code" => "#{prefix}#{t.level}"
          }
        end
        roles << {
          "name" => info[:name],
          "code" => prefix,
          "track" => info[:track],
          "levels" => levels
        }
      else
        # Multiple role tracks (e.g. Financial Control with Accountant + Financial Controller)
        config[:role_code_prefixes].each_with_index do |(prefix, info), idx|
          row_num = config[:header_rows][idx]
          xlsx = config[:file] == :product ? product_xlsx : finance_xlsx
          xlsx.default_sheet = family_name

          levels = []
          (5..12).each do |col|
            cell = xlsx.cell(row_num, col)
            next if cell.nil? || cell.to_s.strip.empty?
            level = col - 4
            title = clean_text(cell).split("\n").first&.strip
            levels << {
              "ordinal" => level,
              "title" => title,
              "code" => "#{prefix}#{level}"
            }
          end

          roles << {
            "name" => info[:name],
            "code" => prefix,
            "track" => info[:track],
            "levels" => levels
          } unless levels.empty?
        end
      end
    else
      # Group tracks by role code prefix
      grouped = {}
      tracks.each do |t|
        next unless t.code
        prefix = t.code.gsub(/\d+$/, "")
        grouped[prefix] ||= []
        grouped[prefix] << t
      end

      config[:role_code_prefixes].each do |prefix, info|
        role_tracks = grouped[prefix] || []
        next if role_tracks.empty?

        levels = role_tracks.sort_by(&:level).map do |t|
          { "ordinal" => t.level, "title" => t.title, "code" => t.code }
        end

        roles << {
          "name" => info[:name],
          "code" => prefix,
          "track" => info[:track],
          "levels" => levels
        }
      end
    end

    families << { "name" => family_name, "roles" => roles }
  end

  families
end

# ---------------------------------------------------------------------------
# Build capability categories
# ---------------------------------------------------------------------------

def build_capability_categories(core_caps, leadership_caps, role_specific_caps)
  # Use ordered hash to preserve category order
  categories = {}

  add_cap = ->(cat_name, cat_desc, cap_entry) {
    categories[cat_name] ||= {
      "name" => cat_name,
      "description" => cat_desc,
      "capabilities" => []
    }
    # Update description if we have one and existing is nil
    if cat_desc && !categories[cat_name]["description"]
      categories[cat_name]["description"] = cat_desc
    end
    categories[cat_name]["capabilities"] << cap_entry
  }

  core_caps.each_value do |cap|
    cat_name = cap["category"] || "Uncategorized"
    add_cap.call(cat_name, cap["category_description"], {
      "name" => cap["name"],
      "description" => cap["description"],
      "scope" => cap["scope"] || "core",
      "expectations" => cap["expectations"]
    })
  end

  leadership_caps.each_value do |cap|
    cat_name = cap["category"] || "Leadership"
    add_cap.call(cat_name, cap["category_description"], {
      "name" => cap["name"],
      "description" => cap["description"],
      "scope" => cap["scope"] || "leadership",
      "expectations" => cap["expectations"]
    })
  end

  role_specific_caps.each do |cap|
    cat_name = cap["category"] || "Role Specific"
    scope = cap["role_binding"] || cap["sheet"]
    add_cap.call(cat_name, cap["category_description"], {
      "name" => cap["name"],
      "description" => cap["description"],
      "scope" => scope,
      "sheet" => cap["sheet"],
      "expectations" => cap["expectations"]
    })
  end

  categories.values
end

# Clean up nil values recursively
def deep_clean(obj)
  case obj
  when Hash
    obj.each_with_object({}) do |(k, v), h|
      cleaned = deep_clean(v)
      # Keep "description" key even if nil (it's meaningful), skip others if nil/empty
      if k == "description"
        h[k] = cleaned
      elsif !cleaned.nil? && !(cleaned.respond_to?(:empty?) && cleaned.empty?)
        h[k] = cleaned
      end
    end
  when Array
    result = obj.map { |v| deep_clean(v) }.compact
    result.empty? ? nil : result
  else
    obj
  end
end

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

SHEET_CONFIGS = {
  "Data" => {
    file: :product,
    header_rows: [ 2, 3, 4 ],
    track_map: { 0 => "ic", 1 => "ic", 2 => "management" },
    role_family: "Data",
    role_code_prefixes: {
      "AE" => { name: "Analytics Engineer", track: "ic" },
      "DE" => { name: "Data Engineer", track: "ic" },
      "DM" => { name: "Data Manager", track: "management" }
    }
  },
  "Software Engineering" => {
    file: :product,
    header_rows: [ 2, 3 ],
    track_map: { 0 => "ic", 1 => "management" },
    role_family: "Software Engineering",
    role_code_prefixes: {
      "E" => { name: "Software Engineer", track: "ic" },
      "EM" => { name: "Engineering Manager", track: "management" }
    }
  },
  "Product Design" => {
    file: :product,
    header_rows: [ 2 ],
    track_map: { 0 => "ic" },
    role_family: "Product Design",
    assign_codes: true,
    role_code_prefixes: {
      "PD" => { name: "Product Designer", track: "ic" }
    }
  },
  "Product Management" => {
    file: :product,
    header_rows: [ 2 ],
    track_map: { 0 => "ic" },
    role_family: "Product Management",
    role_code_prefixes: {
      "PM" => { name: "Product Manager", track: "ic" }
    }
  },
  "Core 11 and Leadership Capabili" => {
    file: :finance,
    header_rows: [],
    role_family: nil
  },
  "Financial Control" => {
    file: :finance,
    header_rows: [ 2, 3 ],
    track_map: { 0 => "ic", 1 => "ic" },
    role_family: "Financial Control",
    assign_codes: true,
    role_code_prefixes: {
      "FC" => { name: "Accountant", track: "ic" },
      "FCo" => { name: "Financial Controller", track: "ic" }
    }
  },
  "Commercial Finance" => {
    file: :finance,
    header_rows: [ 2 ],
    track_map: { 0 => "ic" },
    role_family: "Commercial Finance",
    assign_codes: true,
    role_code_prefixes: {
      "CF" => { name: "Commercial Finance", track: "ic" }
    }
  },
  "Finance Operations" => {
    file: :finance,
    header_rows: [ 2 ],
    track_map: { 0 => "ic" },
    role_family: "Finance Operations",
    assign_codes: true,
    role_code_prefixes: {
      "FO" => { name: "Finance Operations", track: "ic" }
    }
  }
}.freeze

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

product_file = "tmp/Unified Product - 2025 Career Path Framework.xlsx"
finance_file = "tmp/Finance - 2025 Career Framework.xlsx"

product_xlsx = Roo::Excelx.new(product_file)
finance_xlsx = Roo::Excelx.new(finance_file)

all_roles_by_family = {}
all_role_specific = []
core_capabilities = {}
leadership_capabilities = {}

SHEET_CONFIGS.each do |sheet_name, config|
  xlsx = config[:file] == :product ? product_xlsx : finance_xlsx

  puts "Processing sheet: #{sheet_name}..."
  result = parse_sheet(xlsx, sheet_name, config)

  # Collect roles
  if config[:role_family] && !result[:roles].empty?
    all_roles_by_family[config[:role_family]] = {
      config: config,
      tracks: result[:roles]
    }
  end

  # Collect capabilities with deduplication
  result[:capabilities].each do |cap|
    scope = cap["scope"]

    case scope
    when "core", "finance"
      dedup_key = normalize_for_dedup(cap["name"])
      if core_capabilities[dedup_key]
        merge_illustrations(core_capabilities[dedup_key], cap)
      else
        core_capabilities[dedup_key] = cap.dup
        # Normalize scope to "core" for finance too (they're shared)
        core_capabilities[dedup_key]["scope"] = scope == "finance" ? "finance" : "core"
      end
    when "leadership", "finance_leadership", "stream_leadership"
      dedup_key = normalize_for_dedup(cap["name"])
      if leadership_capabilities[dedup_key]
        existing = leadership_capabilities[dedup_key]
        # Only separate capabilities when they have DIFFERENT scopes AND
        # different canonical expectations (e.g. Product "Prioritisation for
        # Impact" vs Finance "Prioritisation for Impact").
        if existing["scope"] != scope && expectations_differ?(existing, cap)
          scope_key = "#{dedup_key}::#{scope}"
          if leadership_capabilities[scope_key]
            merge_illustrations(leadership_capabilities[scope_key], cap)
          else
            leadership_capabilities[scope_key] = cap.dup
          end
        else
          merge_illustrations(existing, cap)
        end
      else
        leadership_capabilities[dedup_key] = cap.dup
      end
    when "role_specific"
      all_role_specific << cap
    else
      # Unknown scope — treat as role-specific
      all_role_specific << cap
    end
  end
end

# Build output structures
role_families = build_role_families(all_roles_by_family, product_xlsx, finance_xlsx)
capability_categories = build_capability_categories(core_capabilities, leadership_capabilities, all_role_specific)

framework = {
  "framework" => {
    "name" => "me&u 2025 Career Framework",
    "role_families" => role_families,
    "capability_categories" => capability_categories
  }
}

cleaned_framework = deep_clean(framework)

output_path = "db/seeds/meandu_career_framework.yml"
File.write(output_path, YAML.dump(cleaned_framework))

puts "\nYAML written to #{output_path}"
puts "File size: #{File.size(output_path)} bytes"

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

parsed = YAML.safe_load(File.read(output_path))
puts "\n=== Verification ==="
puts "Framework name: #{parsed.dig('framework', 'name')}"
puts "\nRole families: #{parsed.dig('framework', 'role_families')&.length}"
parsed.dig("framework", "role_families")&.each do |rf|
  puts "  #{rf['name']}: #{rf['roles']&.length || 0} roles"
  rf["roles"]&.each do |r|
    level_codes = r["levels"]&.map { |l| l["code"] }&.join(", ")
    puts "    #{r['code']}: #{r['name']} (#{r['track']}) -- #{r['levels']&.length || 0} levels (#{level_codes})"
  end
end

puts "\nCapability categories: #{parsed.dig('framework', 'capability_categories')&.length}"
total_caps = 0
total_expectations = 0
total_illustrations = 0
parsed.dig("framework", "capability_categories")&.each do |cc|
  cap_count = cc["capabilities"]&.length || 0
  total_caps += cap_count
  puts "  #{cc['name']}: #{cap_count} capabilities"
  cc["capabilities"]&.each do |cap|
    exp_count = cap["expectations"]&.length || 0
    ill_count = cap["expectations"]&.sum { |e| e["illustrations"]&.length || 0 } || 0
    total_expectations += exp_count
    total_illustrations += ill_count
    scope_display = cap["scope"].to_s
    scope_display = scope_display[0..40] + "..." if scope_display.length > 43
    puts "    - #{cap['name'][0..60]} [#{scope_display}] (#{exp_count} levels, #{ill_count} illustrations)"
  end
end
puts "\nTOTALS: #{total_caps} capabilities, #{total_expectations} level expectations, #{total_illustrations} illustrations"

# Sanity checks
errors = []
empty_role_code_count = 0
role_code_distribution = Hash.new(0)
parsed.dig("framework", "capability_categories")&.each do |cc|
  cc["capabilities"]&.each do |cap|
    if cap["name"] && cap["name"].length > 100
      errors << "Long capability name (#{cap['name'].length} chars): #{cap['name'][0..60]}..."
    end
    cap["expectations"]&.each do |exp|
      if exp["description"].nil? || exp["description"].empty?
        errors << "Empty expectation for #{cap['name']} at level #{exp['level']}"
      end
      (exp["illustrations"] || []).each do |ill|
        if ill["role_code"].nil? || ill["role_code"].to_s.strip.empty?
          empty_role_code_count += 1
          errors << "Empty role_code in illustration for '#{cap['name']}' at level #{exp['level']}: #{ill['description']&.slice(0, 50)}..."
        else
          role_code_distribution[ill["role_code"]] += 1
        end
      end
    end
  end
end

puts "\nIllustration role_code distribution:"
role_code_distribution.sort_by { |k, _| k }.each do |code, count|
  puts "  #{code}: #{count}"
end

if empty_role_code_count > 0
  errors << "#{empty_role_code_count} illustrations with empty role_code!"
end

if errors.any?
  puts "\nWARNINGS:"
  errors.each { |e| puts "  - #{e}" }
else
  puts "\nNo warnings."
end

puts "\nDone."
