# frozen_string_literal: true

require "test_helper"

# Every Kit and Shared component has a Lookbook preview; previewing the Shell
# stays optional. Checks files only: Lookbook isn't loaded in the test environment.
class KitPreviewsTest < ActiveSupport::TestCase
  LAYERS = %w[kit shared].freeze

  def missing_previews(layer)
    Dir[Rails.root.join("app/components/#{layer}/*.rb")]
      .map { |path| File.basename(path, ".rb") }
      .reject { |name| Rails.root.join("test/components/previews/#{layer}/#{name}_preview.rb").exist? }
  end

  LAYERS.each do |layer|
    should "have a preview for every #{layer.capitalize} component" do
      missing = missing_previews(layer)
      assert_empty missing, "Add a preview at test/components/previews/#{layer}/<name>_preview.rb for:\n#{missing.sort.join("\n")}"
    end
  end
end
