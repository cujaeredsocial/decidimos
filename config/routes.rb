require "sidekiq/web"

Rails.application.routes.draw do
  if Rails.env.development?
    mount LetterOpenerWeb::Engine, at: "/letter_opener"
  end

  # Legacy EnZona callback (the redirect URI registered in EnZona when it was
  # a sign-in provider) -> the verification callback, keeping code/state.
  # See DecidimCujae::Enzona::LEGACY_CALLBACK_PATH.
  get DecidimCujae::Enzona::LEGACY_CALLBACK_PATH, to: redirect(status: 302) { |_params, request|
    [DecidimCujae::Enzona::CALLBACK_PATH, request.query_string.presence].compact.join("?")
  }

  mount Decidim::Core::Engine => '/'
  authenticate :user, ->(u) { u.admin? } do
    mount Sidekiq::Web => "/sidekiq"
    mount DecidimCujae::DbAdminProxy.new => "/pgweb"
  end
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/*
  get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker
  get "manifest" => "rails/pwa#manifest", as: :pwa_manifest

  # Defines the root path route ("/")
  # root "posts#index"
end
