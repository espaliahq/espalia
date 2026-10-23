# frozen_string_literal: true

require "test_helper"

# phlex-views.md → Which Kit component is where agents and people look a job up,
# so its job → component table names every Kit component and nothing that isn't one.
class KitComponentTableTest < ActiveSupport::TestCase
  GUIDE = Rails.root.join("docs/guidelines/phlex-views.md")

  # @return [Array<String>] the Use cell of each row in the section's first table
  def use_cells
    section = GUIDE.read[/^### Which Kit component\n(.*?)^### /m, 1] or flunk "#{GUIDE} has no Which Kit component section"
    rows = section[/^\| You need \| Use \|\n\|[-|]+\|\n((?:\|.*\n)+)/, 1] or flunk "Which Kit component has no You need | Use table"
    rows.lines.map { |row| row.split("|")[2].to_s }
  end

  def named_in_table
    use_cells.flat_map { |cell| cell.scan(/Kit::([A-Z]\w*)/).flatten }.uniq
  end

  def components
    Dir[Rails.root.join("app/components/kit/*.rb")].map { |path| File.basename(path, ".rb").camelize }
  end

  should "name every Kit component in a row of the table" do
    missing = components - named_in_table
    assert_empty missing, "Add a row to docs/guidelines/phlex-views.md → Which Kit component for:\n#{missing.sort.join("\n")}"
  end

  should "name only Kit components that exist" do
    unknown = named_in_table - components
    assert_empty unknown, "docs/guidelines/phlex-views.md → Which Kit component names components that don't exist:\n#{unknown.sort.join("\n")}"
  end
end
