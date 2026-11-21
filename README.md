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

## Setting up the application

You will need to do some steps before having the app working properly once you have deployed it:

1. Create a System Admin user: `bin/rails decidim_system:create_admin`
1. Visit `<your app url>/system` and log in with your system admin credentials
1. Create a new organization. Check the locales you want to use for that organization, and select a default locale.
1. Set the correct default host for the organization, otherwise the app will not work properly. Note that you need to include any subdomain you might be using.
1. Fill the rest of the form and submit it.

You are good to go!
