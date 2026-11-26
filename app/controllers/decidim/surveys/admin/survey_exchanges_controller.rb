# frozen_string_literal: true

module Decidim
  module Surveys
    module Admin
      # Export and import of survey definitions (decidim.survey JSON format,
      # docs/survey-exchange-formats.md). Lives inside the surveys admin
      # engine, so it gets the component context and the same permission
      # checks as the questions editor (SEC1: :update / :create on
      # :questionnaire, Decidim::Surveys::Admin::Permissions).
      #
      # Routes: config/initializers/survey_exchange.rb.
      class SurveyExchangesController < Admin::ApplicationController
        helper_method :survey, :import_errors, :import_warnings, :responses_report, :responses_errors, :allow_identified_respondents?

        # GET surveys/:id/exchange/export
        def export
          enforce_permission_to(:update, :questionnaire, questionnaire: survey)

          exporter = DecidimCujae::SurveyExchange::Exporter.new(survey, host: request.host)
          data = exporter.call
          send_data JSON.pretty_generate(data), filename: exporter.filename, type: "application/json", disposition: "attachment"
        end

        # GET surveys/:id/exchange/offline
        # Single HTML file to respond the survey without a connection; it
        # produces a decidim.survey.responses file for import_responses.
        def offline
          enforce_permission_to(:update, :questionnaire, questionnaire: survey)

          app = DecidimCujae::SurveyExchange::OfflineApp.new(survey, host: request.host)
          send_data app.call, filename: app.filename, type: "text/html; charset=utf-8", disposition: "attachment"
        end

        # GET surveys/:id/exchange/import
        def edit
          enforce_permission_to(:update, :questionnaire, questionnaire: survey)
        end

        # POST surveys/:id/exchange/import
        def update
          enforce_permission_to(:update, :questionnaire, questionnaire: survey)

          with_uploaded_json do |data, sha256|
            DecidimCujae::SurveyExchange::ImportSurvey.call(survey, data, current_user, as_new: params[:as_new] == "1", file_sha256: sha256) do
              on(:ok) do |report|
                flash[:notice] = success_message(report)
                redirect_to edit_questions_questions_survey_path(survey)
              end
              on(:invalid) do |error|
                import_failed(error, :edit)
              end
            end
          end
        end

        # POST surveys/:id/exchange/responses
        # Imports participations (decidim.survey.responses, spec section 4).
        def import_responses
          enforce_permission_to(:update, :questionnaire, questionnaire: survey)

          with_uploaded_json(limit: DecidimCujae::SurveyExchange::RESPONSE_LIMITS[:file_bytes], on_error: :responses_failed) do |data, sha256|
            allow_identified = params[:allow_identified_respondents] == "1" && allow_identified_respondents?
            report = failure = nil
            # Decidim::Command runs the `on` blocks on the command, so
            # instance variables set there would not reach the view.
            DecidimCujae::SurveyExchange::ImportResponses.call(survey, data, current_user, allow_identified_respondents: allow_identified, file_sha256: sha256) do
              on(:ok) { |result| report = result }
              on(:invalid) { |error| failure = error }
            end
            next responses_failed(failure) if failure

            @responses_report = report
            flash.now[report.errors.any? ? :warning : :notice] = responses_message(report)
            render :edit
          end
        end

        # GET survey_exchanges/new
        def new
          enforce_permission_to(:create, :questionnaire)
        end

        # POST survey_exchanges
        def create
          enforce_permission_to(:create, :questionnaire)

          with_uploaded_json do |data, sha256|
            created = nil
            failure = nil
            ActiveRecord::Base.transaction do
              @survey = create_survey(data)
              DecidimCujae::SurveyExchange::ImportSurvey.call(@survey, data, current_user, as_new: true, file_sha256: sha256) do
                on(:ok) { |report| created = report }
                on(:invalid) { |error| failure = error }
              end
              raise ActiveRecord::Rollback if failure
            end

            if created
              flash[:notice] = success_message(created)
              redirect_to edit_questions_questions_survey_path(@survey)
            else
              @survey = nil
              import_failed(failure, :new)
            end
          end
        end

        private

        def survey
          @survey ||= Decidim::Surveys::Survey.where(component: current_component).find(params[:id]) if params[:id]
        end

        # The surveys layout (with the survey side menu) needs a survey.
        def layout_for_action
          return nil if %w(new create).include?(action_name)

          super
        end

        def import_errors
          @import_errors || []
        end

        def import_warnings
          @import_warnings || []
        end

        def with_uploaded_json(limit: DecidimCujae::SurveyExchange::LIMITS[:file_bytes], on_error: nil)
          reject = lambda do |message|
            error = DecidimCujae::SurveyExchange::Error.new(:invalid_file, [message])
            on_error ? send(on_error, error) : import_failed(error, form_action)
          end
          file = params[:file]
          return reject.call(t("decidim.surveys.admin.survey_exchanges.errors.no_file")) unless file.respond_to?(:read)
          return reject.call(t("decidim.surveys.admin.survey_exchanges.errors.too_big", size: limit / 1024)) if file.size > limit

          content = file.read.force_encoding(Encoding::UTF_8)
          begin
            data = JSON.parse(content, max_nesting: 32)
          rescue JSON::ParserError
            return reject.call(t("decidim.surveys.admin.survey_exchanges.errors.not_json"))
          end

          yield data, Digest::SHA256.hexdigest(content)
        end

        attr_reader :responses_report

        def responses_errors
          @responses_errors || []
        end

        # SEC7: attributing responses to real users is for organization admins only.
        def allow_identified_respondents?
          current_user&.admin? ? true : false
        end

        def responses_failed(error)
          @responses_errors = [t("decidim.surveys.admin.survey_exchanges.responses_codes.#{error.code}", default: error.code.to_s)] + error.details
          flash.now[:alert] = t("decidim.surveys.admin.survey_exchanges.import.invalid")
          render :edit, status: :unprocessable_entity
        end

        def responses_message(report)
          t("decidim.surveys.admin.survey_exchanges.responses.result",
            imported: report.imported, skipped: report.skipped.size, errors: report.errors.size)
        end

        def create_survey(data)
          questionnaire = data.is_a?(Hash) && data.dig("survey", "questionnaire").is_a?(Hash) ? data.dig("survey", "questionnaire") : {}
          locales = current_organization.available_locales
          only_locales = lambda do |value|
            texts = value.is_a?(Hash) ? value.select { |k, v| k != "machine_translations" && v.is_a?(String) } : {}
            DecidimCujae::SurveyExchange::Validator.map_locales(texts, locales)[:result]
          end
          form = Admin::SurveyForm.from_params(
            title: only_locales.call(questionnaire["title"]),
            description: only_locales.call(questionnaire["description"]),
            tos: only_locales.call(questionnaire["tos"])
          ).with_context(current_organization:, current_user:, current_component:)

          new_survey = nil
          Admin::CreateSurvey.call(current_component, form) do
            on(:ok) { |s| new_survey = s }
            on(:invalid) { new_survey = nil }
          end
          # Title/tos errors are reported in detail by the import validation.
          new_survey || Decidim::Surveys::Survey.create!(
            component: current_component,
            questionnaire: Decidim::Forms::Questionnaire.new(title: {}, description: {}, tos: {})
          )
        end

        def form_action
          %w(new create).include?(action_name) ? :new : :edit
        end

        def import_failed(error, template)
          @import_errors = [t("decidim.surveys.admin.survey_exchanges.codes.#{error.code}", default: error.code.to_s)] + error.details
          flash.now[:alert] = t("decidim.surveys.admin.survey_exchanges.import.invalid")
          render template, status: :unprocessable_entity
        end

        def success_message(report)
          message = t("decidim.surveys.admin.survey_exchanges.import.success",
                      created: report.created, updated: report.updated, deleted: report.deleted)
          message += " #{t("decidim.surveys.admin.survey_exchanges.import.questions_locked")}" unless report.questions_changed
          if report.warnings.any?
            list = report.warnings.first(3).join("; ")
            list += " …" if report.warnings.size > 3
            message += " #{t("decidim.surveys.admin.survey_exchanges.import.warnings", count: report.warnings.size, list:)}"
          end
          message
        end
      end
    end
  end
end
