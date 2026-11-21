# Decidim app customization — verified reference (v0.31.5 / v0.32.2)

All paths relative to the tag root (`~/.cache/decidim-src/<tag>/`). "Both" = identical in 0.31.5 and 0.32.2.
Stack: 0.31.5 = Rails ~> 7.2, Ruby ~> 3.3, shakapacker ~> 8.3; 0.32.2 = Rails ~> 8.1, Ruby ~> 3.4, shakapacker ~> 9.7 (`decidim-core/decidim-core.gemspec`).

## 1. Configuration

### No generated initializer, no secrets.yml
- Since 0.31.0 `config/initializers/decidim.rb` is NOT generated; create it yourself if needed (`docs/modules/configure/pages/initializer.adoc` l.3). The app generator templates (`decidim-generators/lib/decidim/generators/app_templates/`) contain no decidim initializer.
- `secrets.yml`: no reference to `Rails.application.secrets` / `secrets.yml` in any `decidim-*/lib|app|config` in either tag. Config comes from ENV via `Decidim::Env` defaults. **Stale docs**: `docs/modules/services/pages/social_providers.adoc` still says "config/secrets.yml" — ignore that, use `Decidim.configure`.
- Format (initializer.adoc): `Decidim.configure do |config| config.application_name = "..." end`.

### How defaults are read
- 0.31.5 `decidim-core/lib/decidim/core.rb`: `include ActiveSupport::Configurable` (l.148) + 66 `config_accessor :x do Decidim::Env.new("ENV_NAME", default)... end`.
- 0.32.2 same file: `class << self; def config = self; def configure; yield self; end; end` (l.153-159) + `mattr_accessor :x, default: Decidim::Env.new(...)`. Same option names; read as `Decidim.x`.
- Defaults are computed when `decidim/core` is required (boot) → ENV must be set before Rails boots; changes need a restart.
- `Decidim::Env` (`decidim-core/lib/decidim/env.rb`, both): `Env.new(name, default)`; `value` = ENV presence || default; `blank?` true for `""`, nil, `0`, `false`, `no` (FALSE_VALUES); `present?`, `to_i`, `to_f`, `to_array(separator: ",")` (strips), `to_boolean_string`, `default_or_present_if_exists` (returns default unless the var is set at all — used for `"auto"` tri-state vars).
- Organization-level (System panel) settings override some globals: locales subset, CSP, omniauth, SMTP, etc.

### Important ENV vars (core.rb; docs: configure/pages/environment_variables.adoc)
| ENV | Decidim config | Default (source) |
|---|---|---|
| DECIDIM_APPLICATION_NAME | application_name | "My Application Name" |
| DECIDIM_MAILER_SENDER | mailer_sender | "change-me@example.org" |
| DECIDIM_AVAILABLE_LOCALES | available_locales (to_array) | en,bg,ar,ca,cs,…,es,…(full list) |
| DECIDIM_DEFAULT_LOCALE | default_locale | "en" |
| DECIDIM_FORCE_SSL | force_ssl | "auto" → true in production/staging |
| DECIDIM_CORS_ENABLED | cors_enabled | false |
| DECIDIM_SYSTEM_ACCESSLIST_IPS | system_accesslist_ips | [] |
| DECIDIM_CURRENCY_UNIT | currency_unit | "€" |
| DECIDIM_ENABLE_HTML_HEADER_SNIPPETS | enable_html_header_snippets | false |
| DECIDIM_SOCIAL_SHARE_SERVICES | social_share_services | "X, Facebook, WhatsApp, Telegram" |
| DECIDIM_CONSENT_COOKIE_NAME | consent_cookie_name | "decidim-consent" |
| DECIDIM_EXPIRE_SESSION_AFTER | expire_session_after (minutes) | 30 |
| DECIDIM_ENABLE_REMEMBER_ME | enable_remember_me | "auto" → true |
| DECIDIM_SESSION_TIMEOUT_INTERVAL | session_timeout_interval (s) | 10 |
| DECIDIM_OAUTH_ACCESS_TOKEN_EXPIRES_IN | oauth_access_token_expires_in (minutes) | 120 |
| DECIDIM_UNCONFIRMED_ACCESS_FOR | unconfirmed_access_for (days) | 0 |
| DECIDIM_THROTTLING_MAX_REQUESTS / _PERIOD | throttling_max_requests / throttling_period (min) | 100 / 1 |
| DECIDIM_MAXIMUM_ATTACHMENT_SIZE / AVATAR_SIZE | maximum_attachment_size / maximum_avatar_size (MB) | 10 / 5 |
| DECIDIM_ENABLE_MACHINE_TRANSLATION | enable_machine_translations | false |
| DECIDIM_MACHINE_TRANSLATION_SERVICE | machine_translation_service (class name) | nil |
| DECIDIM_SERVICE_WORKER_ENABLED | service_worker_enabled | true except development |
| DECIDIM_FOLLOW_HTTP_X_FORWARDED_HOST | follow_http_x_forwarded_host | false |
| DECIDIM_ADMIN_PASSWORD_STRONG | admin_password_strong | true |
| DECIDIM_CACHE_EXPIRATION_TIME | cache_expiry_time (min) | 1440 |
| STORAGE_PROVIDER / STORAGE_CDN_HOST | storage_provider / storage_cdn_host | "local" / nil |
| OMNIAUTH_{FACEBOOK_APP_ID,TWITTER_API_KEY,GOOGLE_CLIENT_ID}(+secret) | omniauth_providers[:facebook/:twitter/:google_oauth2] | enabled iff ID present |
| SMTP_ADDRESS/PORT(587)/USERNAME/PASSWORD/DOMAIN/AUTHENTICATION("plain")/STARTTLS_AUTO | injected into `config/environments/production.rb` | `decidim-generators/lib/decidim/generators/install_generator.rb#smtp_environment` |
| RAILS_LOG_LEVEL, RAILS_LOG_TO_STDOUT, RAILS_ASSET_HOST | production.rb via app_generator (0.31.5 only patches log_level/STDOUT) | — |
Options without ENV (code only): `content_security_policies_extra` ({}), `consent_categories`, `omniauth_providers`, `maps`, `geocoder`, `reference_generator`, `machine_translation_delay`, `enable_etiquette_validator` (true), `content_processors` (ENV in 0.32 table).

## 2. Overriding views, cells, controllers, models

- **Views/partials — filename method** (`docs/modules/customize/pages/views.adoc`): copy the file from the gem to the same relative path in the app (`app/views/layouts/decidim/footer/_mini.html.erb`). Find it via "Rendered …" log lines.
- **Cells**: same filename method — copy template/class to the same path under the app's `app/cells/` (views.adoc "View Models"). Core adds `Rails.root.join("app/views")` and the core gem's `app/cells` to `Cell::ViewModel.view_paths` (`decidim-core/lib/decidim/core/engine.rb` initializer `decidim_core.add_cells_view_paths`).
- **Deface**: documented as optional (views.adoc "Deface method", needs `deface` gem, files `app/overrides/**/*.html.erb.deface`). Not a dependency of any decidim gemspec/Gemfile in either tag — not built in.
- **Logic** (`docs/modules/customize/pages/logic.adoc`): (1) copy the whole file (e.g. `cp $(bundle show decidim-budgets)/app/forms/... app/forms/...`); (2) preferred: concern + include in `config/application.rb`:
```ruby
config.to_prepare do
  Decidim::Budgets::Admin::ProjectForm.include(AdminProjectFormExtensions) # app/forms/concerns/...
end
# controllers/helpers must hook after Decidim's controller init:
initializer "customizations", after: "decidim_core.action_controller" do
  config.to_prepare do
    # controller/helper customizations
  end
end
```
  `decidim_core.action_controller` initializer exists in both tags (`decidim-core/lib/decidim/core/engine.rb`).
- `prepend` pattern for method overrides (`docs/modules/develop/pages/classes/commands.adoc` ~l.258): module with `def attributes; super.merge(...); end` then `Decidim::MyModule::CreateMyResource.prepend(...)`.
- `docs/modules/customize/pages/code.adoc`: monkey patching / decorators (links to gencat `app/decorators` + application.rb config); for larger extensions, a Rails-engine module. Decidim source gives no `app/decorators` loader — if used, you must load them yourself (e.g. `to_prepare` + `Rails.autoloaders.main.ignore`), not a Decidim convention.
- 0.32 only (logic.adoc): extra form context via `form(MyForm).from_params(params, { my_extra: :context })` or overriding `form_context` in a controller concern.
- New pages: plain Rails controllers inheriting `Decidim::ApplicationController` (views.adoc "New pages").

## 3. Extension registries

### View hooks (`decidim-core/lib/decidim/view_hooks.rb`, both)
```ruby
Decidim.view_hooks.register(:user_profile_bottom, priority: Decidim::ViewHooks::HIGH_PRIORITY) do |view_context|
  view_context.cell("my_app/foo", view_context.current_user)
end
```
Priorities: HIGH=1, MEDIUM=2, LOW=3 (sorted ascending). Rendered by `render_hook(name)` (`decidim-core/app/helpers/decidim/view_hooks_helper.rb`). Hooks actually rendered in core views: `:user_profile_bottom` (`decidim-core/app/cells/decidim/profile/details.erb`), `:conference_venues`, plus `card_metadata` items with `:hook`. `:participatory_space_highlighted_elements` is registered by modules but not rendered via `render_hook` in 0.31.5. Admin has its own `Decidim::Admin.view_hooks` (`decidim-admin/lib/decidim/admin.rb`).

### Content blocks (`decidim-core/lib/decidim/content_block_registry.rb`, manifest `content_block_manifest.rb`)
```ruby
Decidim.content_blocks.register(:homepage, :my_block) do |content_block|
  content_block.cell = "decidim/content_blocks/my_block"        # Decidim::ViewModel subclass
  content_block.public_name_key = "decidim.content_blocks.my_block.name" # add i18n key!
  content_block.settings_form_cell = "decidim/content_blocks/my_block_settings_form" # optional
  content_block.images = [{ name: :image_1, uploader: "Decidim::ImageUploader" }] # optional
  content_block.settings { |s| s.attribute :title, type: :text, translated: true }
  content_block.default! # optional (attribute :default)
end
```
Duplicate scope+name raises `ContentBlockAlreadyRegistered`. Scopes: `:homepage`, `:participatory_process_homepage`, `:participatory_process_group_homepage`, `:assembly_homepage`, `:static_page`, `:newsletter_template`. Core homepage blocks: hero, global_menu (0.31 only), sub_hero, highlighted_content_banner, how_to_participate, last_activity, stats, footer_sub_hero, html, global_stats, carousel + module ones (highlighted_processes/assemblies/conferences/initiatives, upcoming_meetings). Example cell: `decidim-core/app/cells/decidim/content_blocks/html_cell.rb`. Admin enables blocks in Admin → Settings → Homepage.

### Menus (`decidim-core/lib/decidim/menu.rb`, docs `customize/pages/menu.adoc`)
```ruby
# config/initializers/decidim_menus.rb
Decidim.menu :menu do |menu|            # block is instance_exec'd in the view context
  menu.add_item :my_page, I18n.t("my_app.menu.my_page"), "/my_page",
                position: 5, if: current_user.present?, active: :exact # also icon_name:, submenu:
end
Decidim.menu :user_menu do |menu|
  menu.remove_item :authorizations
  menu.move :authorizations, before: :notifications_settings
end
```
Note: options are plain keyword hash (`add_item(identifier, label, url, options = {})`), NOT `options: {...}` as menu.adoc shows. `menu.item` is deprecated. Public menus: `:menu` (core item `:root` position 1), `:mobile_menu`, `:user_menu` (items `:account`, `:notifications_settings`, …), `:home_content_block_menu`. Admin: `:admin_menu`, `:admin_menu_modules`, `:admin_settings_menu`, `:admin_user_menu`, `:admin_insights_menu`, `:admin_global_moderation_menu`, `:admin_static_pages_menu`, `:admin_participatory_process_menu`, `:admin_assembly_menu`, …; system: `:system_menu`; `:impersonate_menu`, `:workflows_menu`. Same names in both tags.

### Social shares (`customize/pages/social_shares.adoc`; `decidim-core/lib/decidim/social_share_service_manifest.rb`)
`Decidim.register_social_share_service("Foo") { |s| s.icon = "foo.svg"; s.share_uri = "https://foo.example/share?url=%{url}" }` — `share_uri` must contain `%{url}` (also `%{title}`, `desc`, `image`); `icon_path` = `asset_pack_path("media/images/#{icon}")`; then add "Foo" to `DECIDIM_SOCIAL_SHARE_SERVICES` (case-sensitive). Built-ins registered in `decidim-core/lib/decidim/core/engine.rb`.

### Admin filters (`customize/pages/admin_filters.adoc`)
`Decidim.admin_filter(:proposals) { |filter| filter.add_filters(:x); filter.add_filters_with_values(x: %w(a b)); filter.add_dynamically_translated_filters(...) }` — evaluated at render time in controller context.

## 4. Front-end (Shakapacker)

- App files created by `install_generator.rb#install_decidim_shakapacker`: `app/packs/stylesheets/decidim/decidim_application.scss` (empty), `app/packs/src/decidim/decidim_application.js` (contains `require.context("../../images", true)`), `app/packs/images/.keep`, `package.json`; then `rails decidim:shakapacker:install` (copies `postcss.config.js`, `config/esbuild.config.js`, `tsconfig.json`; `decidim-core/lib/tasks/decidim_shakapacker_tasks.rake`).
- Hook-in points: `decidim-core/app/packs/entrypoints/decidim_core.js` does `import "src/decidim/decidim_application"`; `decidim_overrides.scss` `@use "stylesheets/decidim/decidim_application"`; admin `decidim-admin/.../decidim_admin_overrides.scss` → `stylesheets/decidim/admin/decidim_application`; system → `stylesheets/decidim/system/decidim_application`. Gems ship empty defaults; create the same path in the app to override (styles.adoc). (styles.adoc mentions `app/assets/stylesheets/decidim_application.scss` — wrong path, the real one is under `app/packs/`.)
- Whole-file override: same relative path in app `app/packs/` wins (e.g. `app/packs/stylesheets/decidim/modules/_data-consent.scss`, `app/packs/src/decidim/editor/index.js`) — javascript.adoc/styles.adoc.
- Inline extras: `app/views/layouts/decidim/_head_extra.html.erb` (rendered from `layouts/decidim/_head.html.erb`); per-org "Header snippets" need `DECIDIM_ENABLE_HTML_HEADER_SNIPPETS=true`.
- **Tailwind**: `tailwind.config.js` in app root is regenerated (and gitignored) on every `bin/shakapacker` run by `Decidim::Shakapacker::Runner` → `Decidim::Assets::Tailwind.write_runtime_configuration` (`decidim-core/lib/decidim/shakapacker/runner.rb`). To customize, create `config/tailwind.config.js.erb` (picked up by `decidim-core/lib/decidim/assets/tailwind/instance.rb#configuration_template_path`) copied from `decidim-core/lib/decidim/assets/tailwind/tailwind.config.js.erb`; keep `<%= tailwind_content_directories %>`. Theme colors: `primary/secondary/tertiary: withOpacity("--primary-rgb")` (set from admin Appearance), fixed `success #28A745`, `alert #ED1C24`, `warning #FFB703`, `gray.{2..6}`, `background.{2..5}`; add under `theme.colors` or `theme.extend`. 0.32 adds `screens: { xs: '375px' }`.
- **Icons**: `icon(name, options)` (`decidim-core/app/helpers/decidim/layout_helper.rb`) renders `<svg><use href=".../media/images/remixicon.symbol.svg#ri-NAME">` (sprite has 3058 Remixicon symbols, `decidim-core/app/packs/images/decidim/remixicon.symbol.svg`). Name must be registered: `Decidim.icons.register(name: "x-line", icon: "x-line", category: "system", description: "", engine: :my_app)`; unregistered → **raises in dev/test** (`Rails.env.local?`), falls back to "other" in prod (`decidim-core/lib/decidim/icon_registry.rb`). `icon(name, ignore_missing: true)` skips the lookup.
- **Images**: put in `app/packs/images/`, use `image_pack_tag`/`asset_pack_path` (images.adoc). Core images can't be overridden. Webpack rule emits `media/images/[name]-[hash][ext]` — directory flattened — so manifest key is `media/images/<basename>` (core `app/packs/images/decidim/brands/google.svg` is referenced as `"media/images/google.svg"`). Avoid basename collisions with core images.
- **Omniauth provider icon** (`decidim-core/app/helpers/decidim/omniauth_helper.rb#oauth_icon`): uses `provider_info[:icon_path]` → `external_icon(path)`, which for `.svg` reads the compiled file from `public/` and inlines it (returns nil if missing / manifest miss); else `provider_info[:icon]` (remixicon name), else `"#{provider}-fill"`. So: file `app/packs/images/enzona.svg` + `icon_path: "media/images/enzona.svg"` (docs example `icon_path: decidim-logo.svg` lacks the `media/images/` prefix). Requires packs compiled and the app's `require.context("../../images", true)`.
- `Decidim.register_assets_path(path)` only does `Rails.autoloaders.main.ignore(path)` (core.rb); core calls it for the app's `app/packs` already. Webpack paths/entrypoints for engines: `Decidim::Shakapacker.register_path` / `register_entrypoints` / `register_stylesheet_import` in `config/assets.rb` (`Decidim::Webpacker.*` deprecated, `decidim-core/lib/decidim/webpacker.rb`).
- Build: `bin/shakapacker` (compile), `bin/shakapacker-dev-server` (port 3035), `bin/rails assets:precompile` in prod (`shakapacker_precompile: true`, output `public/decidim-packs`). Config template `decidim-core/lib/decidim/shakapacker/shakapacker.yml`; app `config/webpack/custom.js` merges into `@decidim/webpacker`.

## 5. Texts & i18n
- Override any key in `config/locales/*.yml` (texts.adoc), e.g. `en.pages.home.footer_sub_hero.footer_sub_hero_body`. Date formats `date.formats.decidim_short` etc. and `number.currency.format` (localization.adoc). Restart required.
- `decidim_core.setup_i18n` initializer sets `config.i18n.available_locales = Decidim.available_locales` and `default_locale` (engine.rb). Orgs choose a subset in System panel.
- Machine translation: class with `initialize(resource, field_name, text, target_locale, source_locale)` + `translate`; set `DECIDIM_ENABLE_MACHINE_TRANSLATION=true`, `DECIDIM_MACHINE_TRANSLATION_SERVICE=ClassName` (`services/pages/machine_translation.adoc`; 0.32: `machine_translations.adoc`, example calls `Decidim::MachineTranslationSaveJob.perform_later(resource, field_name, target_locale, translated_text)`, LibreTranslate example, and org setting "Enable machine translations" must be on). Community gem for admin term editing: decidim-term_customizer (texts.adoc).

## 6. Content Security Policy
- Generator replaces `config/initializers/content_security_policy.rb` with a comment (app_generator.rb#tweak_csp_initializer); CSP is built per request by `Decidim::ContentSecurityPolicy` (`decidim-core/lib/decidim/content_security_policy.rb`, both identical).
- Real defaults (code, docs list is shorter): default-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' *.hereapi.com data:; font-src 'self'; connect-src 'self' *.hereapi.com data:; frame-src 'self' www.youtube-nocookie.com player.vimeo.com; media-src 'self'. No `form-action` by default. Dev adds ws/wss to dev server; `asset_host` auto-added to media/img/script/style.
- Extend globally: `Decidim.configure { |c| c.content_security_policies_extra = { "img-src" => %w(https://*.example.com), "connect-src" => %w(...) } }` (values Array or space-separated String; unknown directive → raise). Per-org: System panel. Per-request: `content_security_policy.append_csp_directive("frame-src", "https://x")` in a before_action.

## 7. Registration mode & data consent
- `Organization#users_registration_mode` enum `[:enabled, :existing, :disabled]` (`decidim-core/app/models/decidim/organization.rb` l.42), set in System panel. `existing`: no sign-up form, login + omniauth still allowed; `disabled`: only external (omniauth) accounts (users_registration_mode.adoc).
- Omniauth providers: `Decidim.omniauth_providers[:name] = { enabled:, icon:/icon_path:, <settings> }`; every key except `:enabled` becomes a System-panel field (`decidim-system/app/views/decidim/system/organizations/_omniauth_provider.html.erb`); per-org values via `organization.enabled_omniauth_providers`. `Decidim::User` passes `omniauth_providers: Decidim::OmniauthProvider.available.keys` to devise at class load (`decidim-core/app/models/decidim/user.rb` l.25) → register providers in an initializer (before User loads). Strategy setup lambda pattern: `decidim-core/config/initializers/omniauth.rb`.
- Data consent (`customize/pages/data_consent.adoc`): categories essential/preferences/analytics/marketing; gate scripts with `<script type="text/plain" data-consent="marketing">` in `_head_extra.html.erb`; add categories via `config.consent_categories = [...]` (re-list all, incl. essential with `_session_id` and `Decidim.consent_cookie_name`) plus i18n keys `layouts.decidim.data_consent.modal.<slug>.{title,description}` and `layouts.decidim.data_consent.details.items.<cookie>.{description,service}`.

## 0.31.5 vs 0.32.2 differences
- Rails 7.2→8.1, Ruby 3.3→3.4, shakapacker 8.3→9.7 (`shakapacker.yml`: `webpack_loader` → `javascript_transpiler` + `assets_bundler`, new `integrity` block).
- Config: `ActiveSupport::Configurable`/`config_accessor` → `mattr_accessor` + `def config = self`. `Decidim.configure`/`Decidim.x` API unchanged.
- `omniauth_providers` defaults: 0.31 stores `Decidim::Env` objects for app_id/secret; 0.32 stores `.value` strings.
- New ENV (0.32): DECIDIM_VERIFICATION_MAX_FAILED_ATTEMPTS (5), DECIDIM_VERIFICATION_UNLOCK_IN (30 min), DECIDIM_VERIFICATION_CODE_EXPIRY_MINUTES (10). Azure storage removed (docs + generator).
- `:global_menu` homepage content block removed in 0.32. Tailwind template adds `xs` screen.
- Docs: logic.adoc gains "form context" section; machine_translation.adoc → machine_translations.adoc.
- Identical: Env, view hooks, menu (doc-comment only), social share manifest, CSP class, icon registry, layout/omniauth helpers, decidim_application.{js,scss} templates, webpack custom.js.

## Gotchas
- ENV defaults are evaluated at boot; setting `ENV[...]` in an initializer is too late — assign `config.x` instead.
- `icon("foo")` raises in development/test if "foo" isn't registered in `Decidim.icons`.
- `external_icon` reads from `public/decidim-packs`; an un-compiled or mistyped `icon_path` silently renders nothing. Path must be the manifest key `media/images/<file>.svg` (flattened, no subdirs).
- Never edit `tailwind.config.js` (overwritten); use `config/tailwind.config.js.erb`.
- Controller/helper patches must be in `initializer ..., after: "decidim_core.action_controller"` + `to_prepare`.
- `menu.add_item` takes positional options hash; the `if:` / label code runs in view context per request.
- Content block `public_name_key` and settings need locale entries or admin shows missing translations.
- `form-action` isn't in CSP defaults; if you add it, include external OAuth hosts redirected to on form POST.
- Docs mention `config/secrets.yml` (social_providers.adoc) and `app/assets/stylesheets` (styles.adoc): both stale.
