# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Suite d'intégration contre l'environnement de *qualification* de Chorus
# Pro (bac à sable PISTE), par l'adaptateur réel (D-CPP-001). Activée
# seulement si le dossier `~/.config/partiduo/choruspro/` et le fichier
# `~/.config/partiduo/choruspro-sandbox.env` existent et ne sont pas vides
# (sinon : en attente, BLOCAGES B-FIN-002). `CHORUSPRO_SANDBOX=off` la
# désactive.
#
# Variables (fichier `VAR=valeur`, ou environnement) :
# `CHORUSPRO_SANDBOX_CLIENT_ID`, `CHORUSPRO_SANDBOX_CLIENT_SECRET`
# (application PISTE), `CHORUSPRO_SANDBOX_LOGIN`,
# `CHORUSPRO_SANDBOX_PASSWORD` (compte technique de qualification),
# `CHORUSPRO_SANDBOX_RECIPIENT_SIRET` (structure publique de test).
# Dépôt réel seulement avec `CHORUSPRO_SANDBOX_DEPOSIT=on` et un Factur-X
# `facturx.pdf` dans le dossier (numéro d'engagement et code service déjà
# dedans).
#
# Aucun secret n'est affiché ni journalisé : les identifiants restent en
# mémoire, les messages d'échec ne citent que des codes et des numéros.
module Choruspro
  module SpecSupport
    module Qualification
      DIR  = Path.home.join(".config", "partiduo", "choruspro").to_s
      FILE = Path.home.join(".config", "partiduo", "choruspro-sandbox.env").to_s
      VARS = %w[CHORUSPRO_SANDBOX_CLIENT_ID CHORUSPRO_SANDBOX_CLIENT_SECRET CHORUSPRO_SANDBOX_LOGIN
        CHORUSPRO_SANDBOX_PASSWORD CHORUSPRO_SANDBOX_RECIPIENT_SIRET]

      def self.values : Hash(String, String)?
        return if ENV["CHORUSPRO_SANDBOX"]? == "off"
        return if !Dir.exists?(DIR) || Dir.empty?(DIR)
        return unless File.exists?(FILE) && File.size(FILE) > 0
        values = {} of String => String
        File.each_line(FILE) do |line|
          name, separator, value = line.strip.partition('=')
          next if separator.empty? || name.starts_with?('#')
          value = value.sub(/\s+#.*\z/, "").strip
          value = value[1..-2] if value.size >= 2 && value[0] == value[-1] && value[0].in?('"', '\'')
          values[name.strip.lchop("export ").strip] = value
        end
        VARS.each { |name| ENV[name]?.presence.try { |value| values[name] = value } }
        VARS.all? { |name| values[name]?.presence } ? values : nil
      end

      def self.credentials(values : Hash(String, String)) : Credentials
        Credentials.new(values["CHORUSPRO_SANDBOX_CLIENT_ID"], values["CHORUSPRO_SANDBOX_CLIENT_SECRET"],
          values["CHORUSPRO_SANDBOX_LOGIN"], values["CHORUSPRO_SANDBOX_PASSWORD"], "qualification")
      end
    end
  end
end

private alias Q = Choruspro::SpecSupport::Qualification

describe "Chorus Pro — qualification (adaptateur PISTE réel)" do
  values = Q.values

  if values.nil?
    pending("identifiants de qualification absents (~/.config/partiduo/choruspro/, choruspro-sandbox.env ; B-FIN-002)") { }
  else
    credentials = Q.credentials(values)
    siret = values["CHORUSPRO_SANDBOX_RECIPIENT_SIRET"]

    it "accepte les identifiants et lit la structure publique de test" do
      transport = Choruspro::PisteTransport.new
      transport.check(credentials)
      structure = transport.structure(credentials, siret) || raise "structure #{siret} inconnue de la qualification"
      structure.siret.should eq(siret)
    end

    if ENV["CHORUSPRO_SANDBOX_DEPOSIT"]? == "on" && File.exists?(File.join(Q::DIR, "facturx.pdf"))
      it "dépose un Factur-X et suit son flux" do
        transport = Choruspro::PisteTransport.new
        pdf = File.read(File.join(Q::DIR, "facturx.pdf")).to_slice
        deposit = Choruspro::Deposit.new(reference: "PDUO-CPP-QUALIF-#{Time.utc.to_unix}", number: "QUALIF",
          issue_date: Time.utc, recipient_siret: siret, service_code: "", engagement_number: "",
          total_gross: BigDecimal.new(0), currency: "EUR", filename: "facturx.pdf", pdf: pdf)
        remote_id = transport.submit(credentials, deposit)
        remote_id.should start_with("flux:")
        status = transport.status(credentials, remote_id)
        Choruspro::Config.local_status(status.code).should_not be_nil
      end
    end
  end
end
