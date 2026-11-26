# frozen_string_literal: true

# Import/export of survey definitions (decidim.survey JSON format) and
# import of responses (decidim.survey.responses).
# Spec: docs/survey-exchange-formats.md. Code: app/services/decidim_cujae/survey_exchange*,
# app/commands/decidim_cujae/survey_exchange/import_survey.rb and
# app/controllers/decidim/surveys/admin/survey_exchanges_controller.rb.

# Appended to the surveys admin engine (same pattern as
# config/initializers/user_confirmations.rb). Paths are chosen so they do not
# collide with the engine's `resources :surveys` (e.g. GET surveys/:id).
Decidim::Surveys::AdminEngine.routes do
  get "surveys/:id/exchange/export", to: "survey_exchanges#export", as: :export_survey_exchange
  get "surveys/:id/exchange/offline", to: "survey_exchanges#offline", as: :offline_survey_exchange
  get "surveys/:id/exchange/import", to: "survey_exchanges#edit", as: :import_survey_exchange
  post "surveys/:id/exchange/import", to: "survey_exchanges#update"
  post "surveys/:id/exchange/responses", to: "survey_exchanges#import_responses", as: :import_survey_responses_exchange
  get "survey_exchanges/new", to: "survey_exchanges#new", as: :new_survey_exchange
  post "survey_exchanges", to: "survey_exchanges#create", as: :survey_exchanges
end

# SEC10: `match` display conditions run `Regexp.new(value, IGNORECASE)` on
# participant input (Decidim::Forms::DisplayCondition). Bound every regexp
# evaluation so a malicious pattern cannot block a worker (ReDoS).
Regexp.timeout ||= 1.0

# "Import / export" tab in the side menu of each survey (Decidim menus
# accumulate registrations, see Decidim::MenuRegistry.register).
Decidim.menu :admin_surveys_menu do |menu|
  next if @survey.nil? || @survey.new_record?

  menu.add_item :survey_exchange,
                I18n.t("decidim.surveys.admin.survey_exchanges.menu"),
                Decidim::EngineRouter.admin_proxy(@survey.component).import_survey_exchange_path(@survey),
                icon_name: "upload-line",
                position: Float::INFINITY,
                if: allowed_to?(:update, :questionnaire, questionnaire: @survey)
end
