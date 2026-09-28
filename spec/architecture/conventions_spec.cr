# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"
require "../../lib/partiduo-ui-bulma/scripts/api_boundary"

private def source_files(pattern : String) : Array(String)
  Dir.glob(File.join(Choruspro::SpecSupport::ROOT, pattern)).reject(&.includes?("/lib/")).sort!
end

private def flatten_keys(value : YAML::Any, prefix : String = "") : Array(String)
  if hash = value.as_h?
    hash.flat_map { |key, child| flatten_keys(child, prefix.empty? ? key.as_s : "#{prefix}.#{key.as_s}") }
  else
    [prefix]
  end
end

describe "Conventions de l'extension Chorus Pro" do
  it "ouvre chaque fichier source par l'en-tête SPDX" do
    missing = (source_files("{src,ui,spec,config,scripts}/**/*.{cr,sh}") + source_files("*.cr")).reject do |path|
      lines = File.read_lines(path)
      (path.ends_with?(".sh") ? lines[1]? : lines.first?) == "# SPDX-License-Identifier: AGPL-3.0-or-later"
    end
    missing += source_files("ui/**/*.html").reject do |path|
      File.read(path).starts_with?("{# SPDX-License-Identifier: AGPL-3.0-or-later")
    end
    missing.should be_empty
  end

  it "a les mêmes clés de traduction en fr, en et nl" do
    %w[src/choruspro/locales ui/bulma/locales].each do |dir|
      keys = Partiduo::LOCALES.to_h do |locale|
        tree = YAML.parse(File.read(File.join(Choruspro::SpecSupport::ROOT, dir, "#{locale}.yml")))
        {locale, flatten_keys(tree[locale]).sort}
      end
      keys["en"].should eq(keys["fr"])
      keys["nl"].should eq(keys["fr"])
    end
  end

  it "traduit toute clé citée par le code et les gabarits de l'extension" do
    cited = source_files("{src,ui}/**/*.{cr,html}").flat_map do |path|
      File.read(path).scan(/["'](choruspro(?:_ui)?\.[a-z_0-9]+(?:\.[a-z0-9_]+)+)["']/).map(&.[1])
    end.uniq! - Partiduo::Modules[Choruspro::CODE].permissions
    cited.size.should be > 60
    dynamic = [] of String
    Choruspro::Api::STATUSES.each { |code| dynamic << "choruspro.statuses.#{code}" }
    Choruspro::Api::ENVIRONMENTS.each { |code| dynamic << "choruspro.environments.#{code}" }
    %w[submitted status manual error].each { |code| dynamic << "choruspro.actions.#{code}" }
    Partiduo::Modules[Choruspro::CODE].permissions.each do |name|
      dynamic << "choruspro.permissions.#{name.lchop("choruspro.")}"
    end
    missing = Partiduo::LOCALES.flat_map do |locale|
      I18n.with_locale(locale) do
        (cited + dynamic).reject(&.ends_with?(".")).select { |key| I18n.t(key).includes?("missing") && I18n.t(key, count: 2).includes?("missing") }
          .map { |key| "#{locale}:#{key}" }
      end
    end
    missing.should be_empty
  end

  it "range ses tables sous le préfixe choruspro_ (ADR-003 D5)" do
    [Choruspro::Settings, Choruspro::Submission, Choruspro::SubmissionEvent].map(&.db_table)
      .should eq(%w[choruspro_settings choruspro_submission choruspro_submission_event])
  end

  it "ne parle au cœur, depuis ui/bulma, que par Partiduo::Api (ADR-005 D3)" do
    root = Choruspro::SpecSupport::ROOT
    ApiBoundary.scan([File.join(root, "ui")], base: root).map(&.to_s).should eq([] of String)
  end

  it "ne parle au métier de l'extension, depuis ui/bulma, que par Choruspro::Api (ADR-005 D4)" do
    allowed = %w[Api Ui CODE VERSION]
    leaks = source_files("ui/**/*.cr").flat_map do |path|
      File.read_lines(path).each_with_index(1).flat_map do |line, number|
        ApiBoundary.strip_comment(line).scan(/(?<![\w:])Choruspro::([A-Za-z_]\w*)/).compact_map do |match|
          "#{path.lchop(Choruspro::SpecSupport::ROOT + "/")}:#{number} Choruspro::#{match[1]}" unless allowed.includes?(match[1])
        end
      end
    end
    leaks.should be_empty
  end

  it "ne parle au cœur, depuis src/, que par Partiduo::Api (ADR-006 D3)" do
    leaks = source_files("src/**/*.cr").select do |path|
      File.read(path).matches?(/Partiduo::(Invoicing|Accounting|Cards|Core|Vat|Liberal|Micro|Auth)::/)
    end
    leaks.map(&.lchop(Choruspro::SpecSupport::ROOT + "/")).should be_empty
  end

  it "ne journalise ni n'affiche les secrets" do
    credentials = Choruspro::Credentials.new("app", "secret-tres-long", "tech", "mot-de-passe-long", "qualification")
    credentials.to_s.should_not contain("secret-tres-long")
    credentials.inspect.should_not contain("secret-tres-long")
    credentials.to_s.should_not contain("mot-de-passe-long")
  end

  it "n'utilise que des icônes de la planche de l'interface (ADR-005 D5)" do
    lucide = File.join(Choruspro::SpecSupport::ROOT, "lib", "partiduo-ui-bulma", "icons", "lucide")
    known = Dir.glob(File.join(lucide, "*.svg")).map { |path| File.basename(path, ".svg") }
    known.should_not be_empty
    used = source_files("ui/bulma/templates/**/*.html").flat_map do |path|
      File.read(path).scan(/_icon\.html" with name="([a-z0-9-]+)"/).map { |match| "#{path.lchop(Choruspro::SpecSupport::ROOT + "/")} #{match[1]}" }
    end
    used.reject { |item| known.includes?(item.split(' ').last) }.should be_empty
  end

  it "ne cite pas le logiciel d'origine hors documentation (*.adoc, *.md)" do
    # Le nom est assemblé pour que ce fichier ne le contienne pas lui-même.
    name = "no" + "alyss"
    output = IO::Memory.new
    status = Process.run("git", ["grep", "-il", name, "--", ".", ":!*.adoc", ":!*.md"],
      chdir: Choruspro::SpecSupport::ROOT, output: output)
    status.exit_code.should be <= 1
    output.to_s.lines.should be_empty
  end
end
