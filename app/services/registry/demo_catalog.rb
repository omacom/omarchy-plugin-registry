require "rubygems/package"
require "zlib"

module Registry
  # Explicit launch fixtures, never part of db:prepare. They use the normal
  # scan, AI and first-release human gate and record honest demo provenance.
  class DemoCatalog
    PUBLISHER = "omarchy-demo"
    SAMPLES = {
      "hello-bar" => [ "Hello bar (demo)", "Hello, Omarchy" ],
      "focus-label" => [ "Focus label (demo)", "Focus time" ],
      "workspace-label" => [ "Workspace label (demo)", "Workspace one" ]
    }.freeze

    def self.import(admin:)
      raise ArgumentError, "an active admin is required" unless admin&.admin? && admin.suspended_at.nil?

      publisher = Publisher.find_or_initialize_by(name: PUBLISHER)
      if publisher.new_record?
        Publisher.transaction do
          publisher.assign_attributes(kind: :org, claimed: true, allow_reserved: true)
          publisher.save!
          Membership.create!(publisher:, user: admin, role: :owner, founding: true)
        end
      end
      unless publisher.org? && publisher.claimed? && admin.owner_of?(publisher) && !publisher.suspended?
        raise ArgumentError, "demo namespace is not owned by this admin"
      end

      SAMPLES.map do |name, (title, label)|
        existing = publisher.plugins.find_by(name:)&.versions&.find_by(version: "0.1.0")
        if existing
          raise ArgumentError, "refusing to replace a non-demo version" unless existing.system_seed? && existing.provenance["source"] == "demo"
          next existing
        end
        version = PublishVersion.new(user: SeedCatalog.system_user, publisher:, plugin_name: name,
          tarball_bytes: archive(name, title, label), system_seed: true,
          seed_provenance: { "source" => "demo" }).call
        AuditEvent.record!(actor: admin, action: "plugin.seed_demo", subject: version, public: true,
          metadata: { plugin: version.plugin.full_name, version: version.version })
        version
      end
    end

    def self.archive(name, title, label)
      manifest = {
        "schemaVersion" => 1, "id" => "#{PUBLISHER}.#{name}", "name" => title,
        "description" => "Launch demo: a static text label. No system integration or network access.",
        "version" => "0.1.0", "kinds" => [ "bar-widget" ],
        "entryPoints" => { "barWidget" => "Widget.qml" }, "license" => "MIT", "category" => "widgets"
      }
      files = {
        "manifest.json" => JSON.pretty_generate(manifest),
        "Widget.qml" => "import QtQuick\nText { text: #{label.to_json} }\n",
        "README.md" => "# #{title}\n\nA filler plugin for testing the registry. It displays a static label.\nIt does not implement a timer, workspace controls, or other system behavior.\n",
        "LICENSE" => "MIT License\n\nCopyright (c) 2026 Omarchy contributors\n\nPermission is hereby granted, free of charge, to any person obtaining a copy\nof this software and associated documentation files (the \"Software\"), to deal\nin the Software without restriction, including without limitation the rights\nto use, copy, modify, merge, publish, distribute, sublicense, and/or sell\ncopies of the Software, and to permit persons to whom the Software is\nfurnished to do so, subject to the following conditions:\n\nThe above copyright notice and this permission notice shall be included in all\ncopies or substantial portions of the Software.\n\nTHE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR\nIMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,\nFITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE\nAUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER\nLIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,\nOUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE\nSOFTWARE.\n"
      }
      io = StringIO.new
      Zlib::GzipWriter.wrap(io) do |gzip|
        Gem::Package::TarWriter.new(gzip) do |tar|
          files.each do |path, contents|
            tar.add_file_simple(path, 0o644, contents.bytesize) { |file| file.write(contents) }
          end
        end
      end
      io.string
    end
  end
end
