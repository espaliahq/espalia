# frozen_string_literal: true

namespace :mcp do
  desc "List every operation with its tool name, category, approval and file; a web-only one is marked."
  task tools: :environment do
    rows = Operations::Registry.all.map do |op|
      path = Object.const_source_location(op.name).first.delete_prefix("#{Rails.root}/")
      [ Operations::Registry.tool_name_for(op), op.category, op.mcp ? op.approval : "web only", path ]
    end
    width = rows.map { it.first.length }.max
    rows.sort.each { |tool, category, approval, path| puts format("%-#{width}s  %-5s  %-10s  %s", tool, category, approval, path) }
  end
end
