# Decidim auth / registration / sessions / verifications — verified reference (0.31.5, diffs to 0.32.2)

All paths are relative to the tag root (`~/.cache/decidim-src/v0.31.5` unless marked **[0.32]**).
Config lives in `decidim-core/lib/decidim/core.rb` (`config_accessor` in 0.31, `mattr_accessor` in 0.32). Both versions read it as `Decidim.config.x` or `Decidim.x`.
ENV parsing: `decidim-core/lib/decidim/env.rb`. `present?` treats `0`, `false` and `no` as false. `default_or_present_if_exists` returns the default only when the variable is unset.

## 1. Devise on `Decidim::User`
`decidim-core/app/models/decidim/user.rb` L22-28:
```ruby
devise :invitable, :database_authenticatable, :registerable, :confirmable, :timeoutable,
       :recoverable, :trackable, :lockable,
       :decidim_validatable, :decidim_newsletterable, :jwt_authenticatable,   # jwt removed in 0.32
       :omniauthable, omniauth_providers: Decidim::OmniauthProvider.available.keys, ...
       request_keys: [:env], reset_password_keys: [:decidim_organization_id, :email],
       confirmation_keys: [:decidim_organization_id, :email]
devise :rememberable if Decidim.enable_remember_me
```
- Users are scoped per organization. `email` and `nickname` must be unique within the organization, except for deleted or managed users (L46).
- Custom Devise modules: `decidim-core/lib/devise/models/decidim_validatable.rb` and `decidim_newsletterable.rb`.
- Devise settings in `decidim-core/config/initializers/devise.rb`: `lock_strategy = :failed_attempts`, `maximum_attempts = 20`, `unlock_strategy = :both`, `unlock_in = 1.hour`, `unlock_keys = [:email]`, `reconfirmable = true`, `expire_all_remember_me_on_sign_out = true`; `remember_for` stays at the Devise default (commented out).
- The core engine sets `decidim-core/lib/decidim/core/engine.rb` L736-741: `config.allow_unconfirmed_access_for = Decidim.unconfirmed_access_for` and `config.timeout_in = Decidim.config.expire_session_after`.
- The session store, when the app has not set one (engine.rb L573-577): `cookie_store, secure: Decidim.config.force_ssl, expire_after: Decidim.config.expire_session_after`.
- **2FA / OTP: does not exist.** A grep for `two_factor|otp_|totp` over all `*.rb` in both trees finds nothing.

### Session, confirmation and password config (exact names, read in core.rb)
| config | ENV | default | effect / where used |
|---|---|---|---|
| `expire_session_after` | `DECIDIM_EXPIRE_SESSION_AFTER` | `30` (minutes) | Devise `timeout_in`, cookie `expire_after`, `app/controllers/decidim/timeouts_controller.rb`, ephemeral-session expiry (`app/services/decidim/onboarding_manager.rb` L177-181) |
| `enable_remember_me` | `DECIDIM_ENABLE_REMEMBER_ME` | `"auto"` → true | adds `:rememberable`. The checkbox in `views/decidim/devise/sessions/new.html.erb` L22 shows only when `devise_mapping.rememberable?`. When the user is remembered, `expire_session_after` does not apply (comment in core.rb) |
| `session_timeout_interval` | `DECIDIM_SESSION_TIMEOUT_INTERVAL` | `10` (seconds) | how often the JS session timeouter polls |
| `unconfirmed_access_for` | `DECIDIM_UNCONFIRMED_ACCESS_FOR` | `0` (days) | Devise `allow_unconfirmed_access_for`. With 0, a user cannot sign in until confirmed |
| `denied_passwords` | `DECIDIM_DENIED_PASSWORDS` (separator `", "`) | [] | `PasswordValidator#denied?` |
| `password_similarity_length` | `DECIDIM_PASSWORD_SIMILARITY_LENGTH` | 4 | ignores name, email or domain parts shorter than this |
| `admin_password_strong` | `DECIDIM_ADMIN_PASSWORD_STRONG` | true | admins use `admin_password_min_length` |
| `admin_password_min_length` | `DECIDIM_ADMIN_PASSWORD_MIN_LENGTH` | 15 | |
| `admin_password_expiration_days` | `DECIDIM_ADMIN_PASSWORD_EXPIRATION_DAYS` | 90 | |
| `admin_password_repetition_times` | `DECIDIM_ADMIN_PASSWORD_REPETITION_TIMES` | 5 | |
| `user_roles` | `DECIDIM_USER_ROLES` | `admin,user_manager` | organization-level roles |

Password rules are in `decidim-core/app/validators/password_validator.rb`:
- `MINIMUM_LENGTH = 10`, `MAX_LENGTH = 256`, `MIN_UNIQUE_CHARACTERS = 5`. The password must not contain the name, nickname, email, domain or organization host, must not be common or denied, and must not repeat.
- `minimum_length_for(record)` returns `ADMIN_MINIMUM_LENGTH` when `record.admin?` and `admin_password_strong` are both true. The constants are read once, when the class loads.

## 2. Registration and login
- Sign-up: `decidim-core/app/controllers/decidim/devise/registrations_controller.rb`.
  - It runs `before_action :check_sign_up_enabled`, which redirects to the login page unless `current_organization.sign_up_enabled?`.
  - It uses `RegistrationForm` → `Decidim::CreateRegistration` (`app/commands/decidim/create_registration.rb`), which calls `User.create!(email, name, nickname, password, password_updated_at, organization, tos_agreement, newsletter_notifications_at, accepted_tos_version, locale)`.
  - The form uses `invisible_captcha`.
  - Unconfirmed users get the `signed_up_but_<inactive_message>` flash.
- Login: `devise/sessions_controller.rb` runs `before_action :check_sign_in_enabled, only: :create` (L10, L54).
- `users_registration_mode` (`app/models/decidim/organization.rb` L42) is `enum [:enabled, :existing, :disabled]`, with DB default 0 = `enabled`.
  - It is set in **/system → edit organization** (`decidim-system/app/views/decidim/system/organizations/edit.html.erb` L25).

| mode | `sign_up_enabled?` | `sign_in_enabled?` | effect |
|---|---|---|---|
| `enabled` | true | true | open registration |
| `existing` | false | true | sign-up form disabled; existing users can log in |
| `disabled` | false | false | email/password login and sign-up both disabled → only OmniAuth (`docs/modules/customize/pages/users_registration_mode.adoc`) |

## 3. OmniAuth
### How providers are defined
- There is **no secrets.yml.** `Decidim.omniauth_providers` is a config hash defined in core.rb (0.31 L734; [0.32] L636).
- The built-in keys are `developer`, `facebook`, `twitter` and `google_oauth2`. Each one is enabled when its ENV is present:
  - `developer`: `enabled: Rails.env.local?`, `icon: "phone-line"`
  - `facebook`: `OMNIAUTH_FACEBOOK_APP_ID` / `OMNIAUTH_FACEBOOK_APP_SECRET` (keys `app_id`, `app_secret`, `icon_path`)
  - `twitter`: `OMNIAUTH_TWITTER_API_KEY` / `OMNIAUTH_TWITTER_API_SECRET` (keys `api_key`, `api_secret`)
  - `google_oauth2`: `OMNIAUTH_GOOGLE_CLIENT_ID` / `OMNIAUTH_GOOGLE_CLIENT_SECRET` (keys `client_id`, `client_secret`)
- In 0.31 these values are `Decidim::Env` objects. In 0.32 they are `.value` strings.
- The docs (`services/pages/social_providers.adoc`) still say "configure it in `config/secrets.yml`". That text is **stale**; the code reads only this hash.
- `Decidim::OmniauthProvider` (`app/models/decidim/omniauth_provider.rb`): `.available` returns the whole hash; `.enabled` returns the entries with `enabled == true`.
- Middleware: `decidim-core/config/initializers/omniauth.rb` registers only `:developer` (fields name/nickname/email), `:decidim`, `:facebook` (scope email), `:twitter` and `:google_oauth2`.
  - Each one uses a `setup:` lambda that looks up `Organization.find_by(host: request.host).enabled_omniauth_providers[provider]` and copies the credentials into the strategy options **per request**.
  - Credentials are therefore per organization.

### Per-organization config (/system)
- `Organization#enabled_omniauth_providers` (organization.rb L154-224):
  - When `omniauth_settings` is nil, it returns `OmniauthProvider.enabled`.
  - Otherwise it starts from the globally enabled providers, removes those the tenant set to `omniauth_settings_<p>_enabled=false`, and merges in those the tenant set to `true`, with their settings decrypted through `Decidim::AttributeEncryptor`.
- The /system form (`decidim-system/app/forms/decidim/system/base_organization_form.rb` L49-59) creates one field per key in `Decidim.omniauth_providers[p]`: `omniauth_settings_<p>_enabled` (Boolean) and `omniauth_settings_<p>_<key>` (String) for every other key. Values are encrypted on save (`encrypted_omniauth_settings`).
- The partial `views/decidim/system/organizations/_omniauth_provider.html.erb` labels the fields with I18n `decidim.system.organizations.omniauth_settings.<provider>.<setting>` (and `...omniauth_settings.icon` / `.icon_path`).
- **So every key you add to the provider hash becomes a /system field automatically.**

### Adding a custom OAuth2/OIDC provider (app side)
1. Add the strategy gem (e.g. `omniauth_openid_connect`) or write an `OmniAuth::Strategies::X` class.
2. Add the provider key to `Decidim.omniauth_providers`, keeping the built-in ones. It must be present before `Decidim::User` loads, because the Devise `omniauth_providers:` list is evaluated when the class loads. A natural place is `config/initializers/decidim.rb`:
   ```ruby
   Decidim.configure do |config|
     config.omniauth_providers = config.omniauth_providers.merge(
       myprovider: { enabled: ENV["MYP_CLIENT_ID"].present?, client_id: ENV["MYP_CLIENT_ID"],
                     client_secret: ENV["MYP_CLIENT_SECRET"], site_url: ENV["MYP_SITE"], icon_path: "media/images/myp.svg" })
   end
   ```
   This snippet is adapted from the docs example. Note that `Decidim.configure` yields `self` in [0.32] (core.rb L156) and comes from `ActiveSupport::Configurable` in 0.31.
3. Register the middleware yourself. Core's `omniauth.rb` hard-codes its provider list, and the docs (`services/pages/social_providers.adoc`, "Custom providers") prescribe this:
   ```ruby
   # config/initializers/omniauth_myprovider.rb
   if Decidim.omniauth_providers[:myprovider]
     Rails.application.config.middleware.use OmniAuth::Builder do
       provider :myprovider, setup: ->(env) {
         org = Decidim::Organization.find_by(host: Rack::Request.new(env).host)
         c = org.enabled_omniauth_providers[:myprovider]
         env["omniauth.strategy"].options[:client_id] = c[:client_id]
         env["omniauth.strategy"].options[:client_secret] = c[:client_secret]
         env["omniauth.strategy"].options[:site] = c[:site_url]
       }, scope: :public
     end
   end
   ```
   For OIDC, put the values under `options[:client_options]` and use the option names of your strategy.
4. Icon: `Decidim::OmniauthHelper#oauth_icon` (`app/helpers/decidim/omniauth_helper.rb` L15-30) uses, in order: per-organization `icon_path`, then the global `icon_path` → `external_icon(path)`; otherwise per-organization `icon` → `icon(name)`; otherwise `icon("<first segment of the provider name split on _>-fill")`.
5. Login buttons (`views/decidim/devise/shared/_omniauth_buttons.html.erb`) loop over `current_organization.enabled_omniauth_providers` and link to `user_<provider>_omniauth_authorize_path` with `method: :post`.
6. Callback URL: `/users/auth/<provider>/callback`. The routes are `devise_for :users, controllers: { omniauth_callbacks: "decidim/devise/omniauth_registrations" }` (`decidim-core/config/routes.rb` L10-20).
   - The controller's `action_missing` serves the callback only when the provider is in `current_organization.enabled_omniauth_providers`.

### Callback flow
Controller: `decidim-core/app/controllers/decidim/devise/omniauth_registrations_controller.rb`.
- `create` builds `OmniauthRegistrationForm` from `request.env["omniauth.auth"]` with these fields:
  - `provider`, `uid`, `name`, `nickname`, `avatar_url` (taken from `info.image`), `raw_data`
  - `oauth_signature = SHA256("#{provider}-#{uid}-#{secret_key_base}")`
- `verified_email` is `info.email` or `session[:verified_email]`.

Command: `decidim-core/app/commands/decidim/create_omniauth_registration.rb`.
1. It checks the signature and raises `InvalidOauthSignature` if it is wrong.
2. **It matches by identity first.** `Identity.find_by(user: organization.users, provider:, uid:)` → if found, it signs in that user and confirms them when the email matches. It then publishes **`decidim.user.omniauth_login`**.
3. **Otherwise it matches by email.** `User.find_or_initialize_by(email: verified_email, organization:)`.
   - An existing user is linked by email, confirmed if needed, and gets `tos_agreement = "1"`.
   - A new user gets a random password, a sanitized name and a normalized nickname, plus the avatar. It raises `NeedTosAcceptance` (→ the `new_tos_fields` view) when the ToS has not been accepted. It calls `skip_confirmation!` only when the provider supplied an email.
4. It creates a `Decidim::Identity(provider, uid, organization)` and publishes **`decidim.user.omniauth_registration`**.
   - Payload: `user_id, identity_id, provider, uid, email, name, nickname, avatar_url, raw_data, tos_agreement, newsletter_notifications_at, accepted_tos_version`.
   - Subscribe with `ActiveSupport::Notifications.subscribe` (`docs/modules/customize/pages/oauth.adoc`).
5. **When the provider sends no email**, the form fails (`validates :email, presence: true`) and the controller renders `omniauth_registrations/new`, where the user types an email.
   - That email is not a verified email, so the account is created **unconfirmed** and confirmation instructions are sent.
   - If the typed email already exists, the save fails and the user sees `email_already_exists`. The accounts are not linked.
- `Decidim::Identity` (`app/models/decidim/identity.rb`): `uid` is unique per `[provider, organization]`, and the user must belong to the same organization.

## 4. Verifications (decidim-verifications)
### Registering a workflow
`Decidim::Verifications.register_workflow(name) { |w| ... }`. Manifest: `decidim-verifications/lib/decidim/verifications/workflow_manifest.rb`.

| attr | default | meaning |
|---|---|---|
| `form` | – | **direct** workflow (`type == "direct"`): the class name of an `AuthorizationHandler` |
| `engine` / `admin_engine` | – | **multistep** workflow. The engine must define `new_authorization_path` and `edit_authorization_path` (README) |
| `action_authorizer` | `DefaultActionAuthorizer` | class name (String) |
| `expires_in` | `0.minutes` (never expires) | |
| `renewable` | **true** | the README says "by default cannot renew", but the code default is true |
| `time_between_renewals` | `1.day` | |
| `metadata_cell` | `"decidim/verifications/authorization_metadata"` | renew modal |
| `icon` | nil | |
| `ephemeral` | false | the authorization can be used by ephemeral (accountless) users |
| `options { \|o\| o.attribute :k, type:, required: }` | | per-permission options shown in the admin permissions UI |

Example from `decidim-generators/lib/decidim/generators/app_templates/verifications_initializer.rb`:
```ruby
Decidim::Verifications.register_workflow(:dummy_authorization_handler) do |workflow|
  workflow.form = "DummyAuthorizationHandler"
  workflow.action_authorizer = "DummyAuthorizationHandler::DummyActionAuthorizer"
  workflow.expires_in = 1.month
  workflow.renewable = true
  workflow.time_between_renewals = 5.minutes
  workflow.options { |o| o.attribute :allowed_postal_codes, type: :string, default: "08001", required: false }
end
```

### `Decidim::AuthorizationHandler`
Defined in `decidim-verifications/app/services/decidim/authorization_handler.rb` as `< Decidim::Form`.
- Built-in attributes: `user`, `handler_name`, `tos_agreement`. `tos_agreement` is required only for ephemeral users who have not accepted the ToS.
- Override these methods:
  - `unique_id`: nil means no uniqueness check. Otherwise an `Authorization` with the same `name` and `unique_id` on another user in the organization makes it a duplicate.
  - `metadata` (Hash): stored in `authorization.metadata` and compared against the permission options.
  - `verification_metadata` and `verification_attachment`.
  - Your ActiveModel validations.
- `handler_name` is `name.demodulize.underscore`. The form partial is `"#{handler_name without _handler}/form"`.
- See the example at `app_templates/dummy_authorization_handler.rb`. The test helper is `it_behaves_like "an authorization handler"`.

### `DefaultActionAuthorizer#authorize`
Source: `lib/decidim/verifications/default_action_authorizer.rb`. It returns `[status, data]`:
- `:missing` when there is no authorization
- `:expired`
- `:pending` when not granted (`verified_at` is nil)
- `:unauthorized` when a metadata field does not equal the option value
- `:incomplete` when a required option field is blank in the metadata
- `:ok` otherwise

To customize, subclass it and override `authorize` and/or `redirect_params`.

### Built-in workflows
| name | type | source | condition |
|---|---|---|---|
| `id_documents` | multistep | `lib/decidim/verifications/id_documents/workflow.rb` | ENV `VERIFICATIONS_DOCUMENT_TYPES` (README) |
| `postal_letter` | multistep | `.../postal_letter/workflow.rb` | |
| `csv_census` | multistep | `.../csv_census/workflow.rb` | |
| `sms` | multistep | `.../sms/engine.rb` L21-27 | only if `Decidim.sms_gateway_service` (ENV `DECIDIM_SMS_GATEWAY_SERVICE`) is set. The gateway class takes `(mobile_phone, code)` and defines `#deliver_code` |

### Enabling a workflow and requiring it
1. **/system → organization → "Available authorizations"** check boxes (`available_authorizations` string array; `decidim-system/.../organizations/edit.html.erb` L34).
2. Admin: open the component → **Permissions** (route `resource :permissions, controller: "component_permissions"` in `decidim-participatory_processes/lib/.../admin_engine.rb` L64). For each action:
   - choose one or more handlers
   - fill in the options declared in the workflow (for example, allowed postal codes)
   - Resource-level permissions also exist (`resource_permissions_controller.rb`).
   - Example actions: surveys `respond`; debates `create like comment`; proposals `like vote create withdraw amend comment vote_comment`; meetings `join comment` (from each `lib/decidim/<mod>/component.rb`).
3. Users verify themselves at `decidim_verifications.authorizations_path` (account → Authorizations).

### Conflicts and transfers (`app/commands/decidim/verifications/authorize_user.rb`)
- **Both users ephemeral** (`user_transferrable?`): the session switches to the existing ephemeral user (`:transfer_user`).
- **Duplicate owned by a deleted or ephemeral user** (`transferrable?`): `authorization.transfer!` creates a `Decidim::AuthorizationTransfer` (`decidim-core/app/models/decidim/authorization_transfer.rb`).
  - Modules move their records with `Decidim::AuthorizationTransfer.register(:mod) { |t, handler| t.move_records(Klass, :decidim_author_id) }`.
  - Core registers its records in `core/engine.rb` L744+.
  - If transfers are disabled, `DisabledError` is raised and handled as a conflict.
- **Any other invalid duplicate**: creates or increments a `Decidim::Verifications::Conflict(current_user, managed_user, unique_id, times)` and notifies the organization admins (`ManagedUserErrorEvent`).
  - Admins resolve it at **Admin → Participants → Impersonations → Verification conflicts** (`decidim-admin/.../conflicts_controller.rb`).
  - `Admin::TransferUser` copies the new user's email, password and confirmation onto the managed user and sets `managed = false`.

### Ephemeral (accountless) participation (exists in 0.31 and 0.32)
- Flow:
  1. A visitor triggers an action whose required handlers are **all** `ephemeral: true` (`AuthorizationStatusCollection#ephemeral?`, `decidim-core/app/services/decidim/action_authorizer.rb` L149).
  2. `AuthorizationsController#set_ephemeral_user` (before `renew_onboarding_data`) runs `CreateEphemeralUser`.
  3. That command creates a `managed: true` user with `extended_data: {ephemeral: true, ...}`, confirms it, and signs it in.
- Ephemeral users can only use ephemeral handlers (`authorize_handler` raises `ActionForbidden`).
- The session is destroyed after `expire_session_after` (`EphemeralSessionChecker`, `OnboardingManager#expired?`).
- Separately, surveys have a per-survey **`allow_unregistered`** setting (`decidim-surveys/app/forms/decidim/surveys/admin/survey_settings_form.rb`) that lets anonymous visitors respond. It identifies them with a session token.

## 5. Impersonation / managed users
- Menu: Admin → Participants → **Impersonations** (`impersonatable_users`). Routes are in `decidim-admin/config/routes.rb` L56-59 and L102 (conflicts).
- Permissions (`decidim-admin/app/permissions/decidim/admin/permissions.rb` L188-222; the same logic is in `user_manager_permissions.rb`, available to `user_manager`):
  - **create a managed user**: requires `!organization.available_authorizations.empty?` (and accepted admin terms for admins).
  - **impersonate**:
    - requires `available_authorization_handlers.any?`. This is `available_authorizations & Decidim.authorization_handlers`, so **only direct (form) workflows count**. A multistep-only setup does not enable impersonation.
    - the target must not be an admin and must have no roles.
    - the admin must have no active log.
  - **promote**: the user is managed and the admin has no active `ImpersonationLog`.
- `Admin::ImpersonateUser` (`decidim-admin/app/commands/decidim/admin/impersonate_user.rb`):
  - saves the managed user if new
  - runs `Authorization.create_or_update_from(form.authorization)`. The admin fills in the handler form, and `reason` is required for non-managed users.
  - creates an `ImpersonationLog(admin, user, reason, started_at)`
  - writes an admin-only action log
  - enqueues `ExpireImpersonationJob` after `ImpersonationLog::SESSION_TIME_IN_MINUTES = 30`
- An existing managed user is found again through the `unique_id` of the handler (`impersonations_controller.rb#existing_managed_user`).
- Promotion (`managed_users/promotions`) invites a managed user by email so they can take over their account.

## 6. Roles
- **Organization level** (`Decidim.user_roles`):
  - `admin` is the boolean `users.admin`.
  - `user_manager` lives in `users.roles[]`; `User#role?` is at user.rb L137.
  - Grant both at **Admin → Participants → Admins** (`decidim-admin/.../users_controller.rb`, `InviteUserForm` + `InviteAdmin`).
  - A `user_manager` can see the dashboard, manage managed users, impersonate and view participants (`user_manager_permissions.rb`).
- **Space level**: `ParticipatorySpaceUser::ROLES = %w(admin collaborator moderator evaluator)` (`decidim-core/lib/decidim/participatory_space_user.rb` L9).
  - The role is called **evaluator**, not valuator.
  - Grant it at Admin → Process/Assembly → **Members/"Process admins"** (`resources :user_roles` in `participatory_processes/admin_engine.rb` L40).
  - What each role can do (`decidim-participatory_processes/app/permissions/.../permissions.rb` L206-249):

| role | can |
|---|---|
| admin (space) | everything inside the space: components, component_data export, moderation, steps, user roles, share tokens, import |
| moderator | `:moderation` |
| collaborator | `:preview` (0.31); `:read` + `:preview` in [0.32] |
| evaluator | `:read :component` and `:export :component_data` |

- **Seeing survey results:**
  - The component admin base requires `:read :component` for every action (`decidim-admin/app/controllers/decidim/admin/components/base_controller.rb` L22-28; `on:` is not a valid `before_action` option, so it applies to all actions).
  - `decidim-surveys/app/permissions/decidim/surveys/admin/permissions.rb` allows `:questionnaire_responses` `index/show/export_response` for **any** user in the admin scope.
  - So a space **admin**, and by these rules an **evaluator**, should reach Admin → survey → Responses. **Check the evaluator case in a running app.**
- **Debates/comments ("forum")** are public. Admin-side moderation needs the moderator or space admin role.

## 7. Restricting access
- `force_users_to_authenticate_before_access_organization`: a /system organization checkbox (`edit.html.erb` L22). It is enforced by `decidim-core/app/controllers/concerns/decidim/force_authentication.rb`, which redirects to sign-in except for `/locale`, `/manifest.webmanifest` and static pages with `allow_public_access`.
- Private spaces:
  - 0.31: `private_space` boolean on processes/assemblies, plus `is_transparent` on assemblies, plus `Decidim::ParticipatorySpacePrivateUser`. Managed under the space's "Private participants".
  - [0.32]: `access_mode` enum `{open, transparent, restricted}` (`participatory_process.rb` L70-75); `Decidim::ParticipatorySpace::Member` (migration `20251205122428_rename_participatory_space_private_users_to_members.rb`).

## 0.31.5 vs 0.32.2 differences (verified by diff)
- `core.rb`: `config_accessor` (ActiveSupport::Configurable) → `mattr_accessor`, with `def config = self` and `def configure; yield self; end`. Names, ENV variables and defaults are unchanged for every entry listed here. omniauth ENV values are `Env` objects in 0.31 and Strings in 0.32.
- `User`: `:jwt_authenticatable` was removed from core (it moved to `decidim-api/app/models/concerns/decidim/api/user_extension.rb`), and `has_many :impersonation_logs` was added.
- `CreateOmniauthRegistration`: 0.32 retries `RecordNotUnique` up to 2 times (double-click callbacks) and reuses `existing_identity || create_identity`. The controller uses status `:unprocessable_content`.
- Verifications: 0.32 adds a lockout on failed confirmation codes:
  - config `DECIDIM_VERIFICATION_MAX_FAILED_ATTEMPTS` (5), `DECIDIM_VERIFICATION_UNLOCK_IN` (30 min), `DECIDIM_VERIFICATION_CODE_EXPIRY_MINUTES` (10, SMS)
  - code: `Authorization#record_failed_attempt!` / `#locked_for_confirmation?`, used by `confirm_user_authorization.rb` and `csv_census/confirm_census_authorization.rb`
  - revoke commands now run as jobs (`revoke_all_authorizations_job.rb`, `revoke_authorizations_by_condition_job.rb`)
- Admin permissions in 0.32 add `:admin_terms :accept` for admins or any role holder, and `:resource_permission :update`.
- Surveys admin in 0.32 adds `:read` on `:questionnaire`. Collaborators gain `:read`.
- `ForceAuthentication` in 0.32 allows public pages at `/<locale>/pages/<slug>`; 0.31 used `/pages/<slug>`.
- Private space → members / access_mode (see §7).
- Unchanged (0-line diff): `omniauth.rb` initializer, `OmniauthProvider`, `OmniauthRegistrationForm`, `OmniauthHelper`, `WorkflowManifest`, `AuthorizationHandler`, `AuthorizeUser`, `DefaultActionAuthorizer`, `PasswordValidator`, `ImpersonationLog`, space ROLES.

## Gotchas
- The docs are stale where they mention `config/secrets.yml` for providers. The source of truth is `Decidim.omniauth_providers` plus /system `omniauth_settings`.
- Core's `omniauth.rb` registers middleware only for its hard-coded keys. **A custom provider needs its own `OmniAuth::Builder` initializer.**
  - The key must also be in `Decidim.omniauth_providers` before `Decidim::User` loads, or Devise will not create `user_<p>_omniauth_authorize_path`.
  - It must also be enabled for the organization, or `action_missing` raises `ActionNotFound`.
  - Engine `config/initializers` (core's `omniauth.rb`) run before the app's initializers. This is inferred from Rails load order, not from Decidim code.
- In `users_registration_mode = existing`, **OmniAuth still creates new accounts**. `OmniauthRegistrationsController` has no `check_sign_up_enabled`, and the docs confirm this.
- OmniAuth links to an existing account **by verified email**. Any provider that returns an unverified email in `info.email` can take over an account. Only enable providers that verify emails, or override `verified_email`.
- `PasswordValidator` constants are frozen when the class loads. Changing the config at runtime has no effect.
- `renewable` defaults to `true` in code, despite the README.
- Impersonation needs at least one **direct (form)** handler in `available_authorizations`. Users with any role cannot be impersonated.
- An authorization `unique_id` must be stable and normalized (for example, upcase/strip the document number), or duplicates will slip through.
- The `ephemeral` flow triggers only when **all** handlers required by the action are ephemeral. With no handlers at all, ephemeral users are denied (`ok?` returns `!@ephemeral_user`).
- `enable_remember_me` and `expire_session_after` interact: remembered sessions ignore the timeout.
- `DECIDIM_ADMIN_PASSWORD_STRONG=false` (or `0`/`no`) disables strong admin passwords, because `Env#present?` treats those values as false.
