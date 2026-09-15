# frozen_string_literal: true

# Versioned URLs for the app-icon set under public/ (favicon, SVG mark, Apple
# touch icon, web app manifest — see docs/guidelines/app-icons.md).
#
# Production serves public/ with a one-year cache-control header on the
# assumption that everything there is digest-stamped. These files are not —
# their names are fixed by convention — so a regenerated icon would otherwise
# stay stale in every returning browser for up to a year. The `v=` query is a
# digest of the files themselves: regenerate them and every link changes.
module AppIconsHelper
  ICON_FILES = %w[favicon.ico icon.svg icon.png icon-192.png icon-maskable-512.png apple-touch-icon.png manifest.json].freeze

  # @param file [String] a file name under public/, e.g. "icon.svg"
  # @return [String] the root-relative URL with a content-derived version
  def app_icon_path(file)
    "/#{file}?v=#{AppIconsHelper.version}"
  end

  # A short digest over every icon file, memoised per process.
  #
  # @return [String]
  def self.version
    @version ||= begin
      digest = Digest::SHA256.new
      ICON_FILES.each { |f| digest << Rails.root.join("public", f).binread }
      digest.hexdigest.first(8)
    end
  end
end
