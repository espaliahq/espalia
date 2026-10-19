# frozen_string_literal: true

require "test_helper"

# Pins how the AGENTS.md / CLAUDE.md files load the guides. Claude Code loads
# an `@path` import as soon as the file naming it loads, and truncates any
# file over its per-file limit, so a stray import costs every session context
# and a bloated guide silently loses its end. Neither fails anything else.
class AgentGuidanceTest < ActiveSupport::TestCase
  PER_FILE_LIMIT = 150_000
  STARTUP_BUDGET = 150_000
  # What opening a file in one directory may add on top of startup. A guide that
  # outgrows it splits by concern, as framework-explorer.md and assessments.md did.
  DIRECTORY_BUDGET = 100_000

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

      assert_empty oversized, "Claude Code truncates these; split them rather than grow them"
    end
  end

  should "keep what any one directory loads inside the directory budget" do
    startup = loaded_with(root("CLAUDE.md"))
    over = instruction_files.select { it.basename.to_s == "CLAUDE.md" && it.dirname != Rails.root }.filter_map do |file|
      size = (directory_chain(file).flat_map { loaded_with(it).to_a }.uniq - startup.to_a).sum { it.read.size }
      "#{relative(file.dirname)}: #{size}" if size > DIRECTORY_BUDGET
    end

    assert_empty over, "opening a file here loads more than #{DIRECTORY_BUDGET} characters of guides; split the largest"
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

  # Claude Code loads the CLAUDE.md of every directory between the root and the file it opens.
  def directory_chain(file)
    file.dirname.relative_path_from(Rails.root).descend.map { root(it).join("CLAUDE.md") }.select(&:exist?)
  end

  def markdown_imports(path) = imports(path).select { it.extname == ".md" }

  def loaded_with(path, seen = Set.new)
    return seen if seen.include?(path) || !path.exist?

    seen << path
    imports(path).each { loaded_with(it, seen) }
    seen
  end
end
