FROM ruby:3.1.3-slim

# The Ruby 3.1.3 images are built on Debian 11 (bullseye), whose packages now live on archive.debian.org.
RUN sed -i "s|deb.debian.org|archive.debian.org|g" /etc/apt/sources.list && \
    apt-get update -qq && \
    apt-get install -y --no-install-recommends build-essential default-libmysqlclient-dev git pkg-config && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
ENV RAILS_ENV=development \
    BUNDLE_PATH=/usr/local/bundle

COPY Gemfile Gemfile.lock ./
RUN gem install bundler -v 2.3.26 && bundle install --jobs 4

COPY . .

ENTRYPOINT ["bin/docker-entrypoint"]
EXPOSE 3000
CMD ["bin/rails", "server", "-b", "0.0.0.0", "-p", "3000"]
