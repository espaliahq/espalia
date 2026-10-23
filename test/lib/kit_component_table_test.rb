# frozen_string_literal: true

require "test_helper"

# phlex-views.md → Which Kit component is where agents and people look a job up,
# so it names every Kit component and nothing that isn't one.
class KitComponentTableTest < ActiveSupport::TestCase
  GUIDE = Rails.root.join("docs/guidelines/phlex-views.md")

  def table
    GUIDE.read[/^### Which Kit component\n(.*?)^### /m, 1] or flunk "#{GUIDE} has no Which Kit component section"
  end

  def components
    Dir[Rails.root.join("app/components/kit/*.rb")].map { |path| File.basename(path, ".rb").camelize }
  end

  should "name every Kit component" do
    missing = components.reject { |name| table.include?("Kit::#{name}") }
    assert_empty missing, "Add a row to docs/guidelines/phlex-views.md → Which Kit component for:\n#{missing.sort.join("\n")}"
  end

  should "name only Kit components that exist" do
    unknown = table.scan(/Kit::([A-Z]\w*)/).flatten.uniq - components
    assert_empty unknown, "docs/guidelines/phlex-views.md → Which Kit component names components that don't exist:\n#{unknown.sort.join("\n")}"
  end
end
