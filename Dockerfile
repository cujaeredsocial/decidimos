FROM ruby:3.3.4

RUN apt-get update -qq && apt-get install -y \
    build-essential \
    libpq-dev \
    git \
    curl \
    imagemagick \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*

RUN npm install -g yarn

WORKDIR /app

COPY package.json package-lock.json .

RUN yarn install

COPY Gemfile Gemfile.lock* ./

# RUN bundle install --without development test --jobs 4 --retry 3
RUN bundle install

COPY . .

# RUN RAILS_ENV=production bundle exec rake assets:precompile
RUN bundle exec rake assets:precompile

RUN rm -rf /app/tmp/cache /app/public/assets/.sprockets-manifest-* \
    && rm -rf /usr/local/bundle/cache/*.gem

# ENV RAILS_ENV=production \
#   RAILS_SERVE_STATIC_FILES=true \
#    RAILS_LOG_TO_STDOUT=true

EXPOSE 3000

ENTRYPOINT ["/app/bin/docker-entrypoint"]

CMD ["./bin/rails", "server", "-b", "0.0.0.0"]
