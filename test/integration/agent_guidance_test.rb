# frozen_string_literal: true

require "test_helper"

# Pins how the AGENTS.md / CLAUDE.md files load the guides. Claude Code loads
# an `@path` import as soon as the file naming it loads, and truncates any
# file over its per-file limit, so a stray import costs every session context
# and a bloated guide silently loses its end. Neither fails anything else.
class AgentGuidanceTest < ActiveSupport::TestCase
  PER_FILE_LIMIT = 150_000
  STARTUP_BUDGET = 150_000

  # Over the limit today and due to be split; drop each entry once it is.
  OVERSIZED = %w[
    docs/guidelines/framework-explorer.md
    docs/guidelines/assessments.md
  ].freeze

  INSTRUCTION_FILES = Rails.root.glob("{,app/**/,test/**/,docs/**/,lib/**/,config/**/}{AGENTS,CLAUDE}.md").freeze
  IMPORT = %r{(?:\A|[\s|(,])@([^\s`|),]+\.md)\b}

  def relative(path) = path.relative_path_from(Rails.root).to_s

  def imports(path)
    text = path.read.gsub(/^```.*?^```/m, "").gsub(/`[^`\n]*`/, "")
    text.scan(IMPORT).flatten.map { |target| path.dirname.join(target).cleanpath }
  end

  def loaded_with(path, seen = Set.new)
    return seen if seen.include?(path)

    seen << path
    imports(path).each { |target| loaded_with(target, seen) if target.exist? }
    seen
  end

  context "the files every session loads" do
    should "import nothing from the root AGENTS.md" do
      assert_empty imports(Rails.root.join("AGENTS.md")).map { relative(it) },
        "link to a guide from the root AGENTS.md; an @ import loads it into every session"
    end

    should "import only AGENTS.md from the root CLAUDE.md" do
      assert_equal [ "AGENTS.md" ], imports(Rails.root.join("CLAUDE.md")).map { relative(it) }
    end

    should "import nothing from app/AGENTS.md, which loads for any file under app/" do
      assert_empty imports(Rails.root.join("app/AGENTS.md")).map { relative(it) }
    end

    should "stay inside the startup budget" do
      size = loaded_with(Rails.root.join("CLAUDE.md")).sum { it.read.size }

      assert_operator size, :<=, STARTUP_BUDGET, "a session starts with #{size} characters of instructions"
    end
  end

  context "every import" do
    should "point at a file that exists" do
      missing = INSTRUCTION_FILES.flat_map do |file|
        imports(file).reject(&:exist?).map { "#{relative(file)} → #{relative(it)}" }
      end

      assert_empty missing, "an import that resolves to nothing loads nothing, silently"
    end

    should "fit under Claude Code's per-file limit" do
      oversized = INSTRUCTION_FILES.flat_map { imports(it) }.uniq.select(&:exist?)
        .select { it.read.size > PER_FILE_LIMIT }.map { relative(it) }

      assert_empty oversized - OVERSIZED, "Claude Code truncates these; split them rather than grow them"
      assert_empty OVERSIZED - oversized, "now under the limit — remove from OVERSIZED"
    end
  end
end
