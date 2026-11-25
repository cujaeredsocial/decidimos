# decidimos

Free Open-Source participatory democracy, citizen participation and open government for cities and organizations

This is the open-source repository for decidim_cujae, based on [Decidim](https://github.com/decidim/decidim).

## Develop

```sh
docker compose -f docker-compose.dev.yml up -d
```

- App: http://localhost:3000
- pgAdmin: http://localhost:5050

Setup dev database

```sh
docker compose -f docker-compose.dev.yml exec app bin/rails db:create db:migrate assets:precompile db:seed
```

## Production

1. Review `.env` (database credentials and other variables).
2. Start the services:

```
docker compose up -d
```

The app listens on port 3000. Postgres data and storage live in `/srv/decidimos/`.

### EnZona environment variables

EnZona is not a sign-in method. It is used to verify that a participant is a real person (the "Verified account" authorization, see `lib/decidim_cujae/verified_account.rb`). Its OAuth2 credentials are read from the environment, not from `/system`:

| Variable | Required | Value |
| --- | --- | --- |
| `ENZONA_CLIENT_ID` | Yes | Client ID of the EnZona (XETID) OAuth application |
| `ENZONA_CLIENT_SECRET` | Yes | Client secret of that application |
| `ENZONA_SITE` | No | EnZona identity server. Default `https://identity.enzona.net` |
| `ENZONA_SSL_VERIFY` | No | `true` to verify EnZona's TLS certificate. Default: not verified |

Set them in `.env` (or in the app's environment variables in CapRover). Without `ENZONA_CLIENT_ID` and `ENZONA_CLIENT_SECRET` the app still boots, but verification with EnZona shows as unavailable and only manual verification by admins works.

The EnZona OAuth application must have this redirect URI registered:

```
https://<your host>/verified_account/authorization/callback
```

Restart the app after changing these variables.

#### Upgrading from the EnZona sign-in version

Older versions used EnZona (`xetid`) as a sign-in provider configured in `/system`. After deploying this version, run once (back up the database first):

```sh
bundle exec rails decidim_cujae:verified_account:migrate_from_enzona_login
```

It removes the old `xetid` sign-in settings from every organization (otherwise the sign-in page shows a broken EnZona button), enables the "Verified account" authorization, and turns every existing EnZona identity into a verified account. The old redirect URI `/users/auth/xetid/callback` is no longer used.

## Setting up the application

You will need to do some steps before having the app working properly once you have deployed it:

1. Create a System Admin user: `bin/rails decidim_system:create_admin`
1. Visit `<your app url>/system` and log in with your system admin credentials
1. Create a new organization. Check the locales you want to use for that organization, and select a default locale.
1. Set the correct default host for the organization, otherwise the app will not work properly. Note that you need to include any subdomain you might be using.
1. Fill the rest of the form and submit it.
1. Edit the organization in `/system` and, under "Available authorizations", check "Verified account (Multi-Step)". Then, in each component's Permissions, require it for the actions that need a real, verified person. See [EnZona environment variables](#enzona-environment-variables).

You are good to go!
