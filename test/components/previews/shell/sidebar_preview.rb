# frozen_string_literal: true

# @label Sidebar
class Shell::SidebarPreview < Lookbook::Preview
  MEMBER_LINKS = [
    { label: "Home", href: "#" },
    { label: "Framework", href: "#" },
    { label: "Assessments", href: "#" },
    { label: "Feedback / Evidence", href: "#" }
  ].freeze

  ADMIN_LINKS = [
    { label: "Home", href: "#" },
    { label: "Frameworks", href: "#" },
    { label: "Assessments", href: "#" },
    { label: "Feedback / Evidence", href: "#" },
    { label: "Calibration", href: "#" },
    { label: "Cycles", href: "#" },
    { label: "Admin", href: "#" }
  ].freeze

  # @param admin toggle
  def playground(admin: false)
    drawer(admin ? ADMIN_LINKS : MEMBER_LINKS)
  end

  # @!group Link sets

  def member
    drawer(MEMBER_LINKS)
  end

  def admin
    drawer(ADMIN_LINKS)
  end

  def home_only
    drawer([ { label: "Home", href: "#" } ])
  end

  def long_label
    drawer([
      { label: "Home", href: "#" },
      { label: "Engineering, Product and Design career framework", href: "#" }
    ])
  end

  # @!endgroup

  private

  def drawer(links)
    render_with_template(template: "shell/sidebar_preview/drawer", locals: { links: links })
  end
end
