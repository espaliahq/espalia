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

  STARTUP_FILES = %w[CLAUDE.md .claude/CLAUDE.md].freeze
  SKIPPED_DIRS = %r{\A(node_modules|vendor|tmp|log|storage|coverage)/}
  IMPORT = %r{(?:\A|[\s|(,])@([^\s`|),]+\.\w+)}

  context "the files every session loads" do
    should "import nothing from the root AGENTS.md" do
      assert_empty relatives(imports(root("AGENTS.md"))),
        "link to a guide from the root AGENTS.md; an @ import loads it into every session"
    end

    should "import only AGENTS.md from the root CLAUDE.md" do
      assert_equal [ "AGENTS.md" ], relatives(imports(root("CLAUDE.md")))
    end

    should "import nothing from app/AGENTS.md, which loads for any file under app/" do
      assert_empty relatives(imports(root("app/AGENTS.md")))
    end

    should "stay inside the startup budget" do
      loaded = STARTUP_FILES.map { root(it) }.select(&:exist?).flat_map { loaded_with(it).to_a }.uniq
      size = loaded.sum { it.read.size }

      assert_operator size, :<=, STARTUP_BUDGET, "a session starts with #{size} characters of instructions"
    end
  end

  context "every file an instruction file loads, directly or through another" do
    should "exist" do
      missing = instruction_files.flat_map do |file|
        loaded_with(file).flat_map { |loaded| markdown_imports(loaded).reject(&:exist?).map { "#{relative(loaded)} → #{relative(it)}" } }
      end.uniq

      assert_empty missing, "an import that resolves to nothing loads nothing, silently"
    end

    should "fit under Claude Code's per-file limit" do
      oversized = relatives(instruction_files.flat_map { loaded_with(it).to_a }.uniq.select { it.read.size > PER_FILE_LIMIT })

      assert_empty oversized - OVERSIZED, "Claude Code truncates these; split them rather than grow them"
    end
  end

  should "list in OVERSIZED only guides that are still over the limit" do
    shrunk = OVERSIZED.reject { root(it).exist? && root(it).read.size > PER_FILE_LIMIT }

    assert_empty shrunk, "now under the limit — remove from OVERSIZED"
  end

  private

  def root(path) = Rails.root.join(path)

  def relative(path) = path.relative_path_from(Rails.root).to_s

  def relatives(paths) = paths.map { relative(it) }

  def instruction_files
    (Rails.root.glob("**/{AGENTS,CLAUDE}.md") + STARTUP_FILES.map { root(it) })
      .select(&:exist?).reject { relative(it).match?(SKIPPED_DIRS) }.uniq
  end

  # Claude Code resolves any `@path`; one that names no file (`@rails/request.js`
  # in prose) loads nothing, so only real files and Markdown targets count.
  def imports(path)
    text = path.read.gsub(/^```.*?^```/m, "").gsub(/`[^`\n]*`/, "")
    text.scan(IMPORT).flatten.map { path.dirname.join(it).cleanpath }.select { it.exist? || it.extname == ".md" }
  end

  def markdown_imports(path) = imports(path).select { it.extname == ".md" }

  def loaded_with(path, seen = Set.new)
    return seen if seen.include?(path) || !path.exist?

    seen << path
    imports(path).each { loaded_with(it, seen) }
    seen
  end
end
