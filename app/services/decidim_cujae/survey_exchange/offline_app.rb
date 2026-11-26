# frozen_string_literal: true

module DecidimCujae
  module SurveyExchange
    # Offline survey app: a single self-contained HTML file (offline_app.html)
    # with the signed `decidim.survey` export embedded in
    # <script type="application/json" id="survey-data">. A participant opens
    # it without a connection, responds, and gets a `decidim.survey.responses`
    # JSON to send to the admin, who imports it with ImportResponses.
    class OfflineApp
      TEMPLATE = File.expand_path("offline_app.html", __dir__)
      DATA_SLOT = '<script type="application/json" id="survey-data"></script>'
      TITLE_SLOT = "<title>Encuesta</title>"
      LANG_SLOT = '<html lang="es">'

      def initialize(survey, host: nil)
        @survey = survey
        @exporter = Exporter.new(survey, host:)
      end

      def call
        data = @exporter.call
        html = File.read(TEMPLATE, encoding: "UTF-8")
        [DATA_SLOT, TITLE_SLOT, LANG_SLOT].each do |slot|
          raise ArgumentError, "offline_app.html: missing #{slot}" unless html.include?(slot)
        end

        organization = @survey.component.organization
        # json_escape turns <, >, &, U+2028 and U+2029 into \uXXXX, so no
        # text of the survey can close the <script> element.
        json = ERB::Util.json_escape(JSON.generate(data))
        html.sub(DATA_SLOT) { %(<script type="application/json" id="survey-data">#{json}</script>) }
            .sub(TITLE_SLOT) { "<title>#{ERB::Util.html_escape(title(data, organization))}</title>" }
            .sub(LANG_SLOT) { %(<html lang="#{ERB::Util.html_escape(organization.default_locale)}">) }
      end

      def filename
        @exporter.filename.sub(/\.survey\.json\z/, ".offline.html")
      end

      private

      def title(data, organization)
        texts = data.dig("survey", "questionnaire", "title") || {}
        texts[organization.default_locale.to_s].presence || texts.except("machine_translations").values.find(&:present?) || "Encuesta"
      end
    end
  end
end
