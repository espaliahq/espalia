# frozen_string_literal: true

namespace :mcp do
  desc "List every MCP tool with its category, approval and the file whose class comment documents it."
  task tools: :environment do
    rows = Operations::Registry.all.map do |op|
      path = Object.const_source_location(op.name).first.delete_prefix("#{Rails.root}/")
      [ Operations::Registry.tool_name_for(op), op.category, op.approval, path ]
    end
    width = rows.map { it.first.length }.max
    rows.sort.each { |tool, category, approval, path| puts format("%-#{width}s  %-5s  %-10s  %s", tool, category, approval, path) }
  end
end
