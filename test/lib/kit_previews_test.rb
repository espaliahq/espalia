# frozen_string_literal: true

require "test_helper"

# Every Kit component has a Lookbook preview. Checks files only: Lookbook
# isn't loaded in the test environment.
class KitPreviewsTest < ActiveSupport::TestCase
  KIT_DIR = Rails.root.join("app/components/kit")
  PREVIEW_DIR = Rails.root.join("test/components/previews/kit")

  # The app shell, deferred until it can be previewed outside a signed-in page.
  SKIPPED = %w[navbar user_menu page_layout tenant_admin_layout impersonation_banner].freeze

  def component_names
    Dir[KIT_DIR.join("*.rb")].map { |path| File.basename(path, ".rb") }
  end

  should "have a preview for every Kit component" do
    missing = (component_names - SKIPPED).reject { |name| PREVIEW_DIR.join("#{name}_preview.rb").exist? }
    assert_empty missing, "Add a preview at test/components/previews/kit/<name>_preview.rb for:\n#{missing.sort.join("\n")}"
  end

  should "only skip components that still exist" do
    stale = SKIPPED - component_names
    assert_empty stale, "Remove from KitPreviewsTest::SKIPPED, the component is gone:\n#{stale.join("\n")}"
  end
end
