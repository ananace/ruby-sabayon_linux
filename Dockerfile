FROM ruby:latest

ENV APP_HOME /app
RUN mkdir $APP_HOME
WORKDIR $APP_HOME

ADD Gemfile* $APP_HOME/
ADD *gemspec $APP_HOME/
ADD lib $APP_HOME/lib/
ADD bin $APP_HOME/bin/

RUN bundle install --without development \
 && echo "#!/bin/sh\n\ncd /app\nexec bundle exec bin/sync-mirror \"\$@\"\n" > /usr/local/bin/sync-mirror \
 && chmod +x /usr/local/bin/sync-mirror \
 && apt-get update -yqq \
 && apt-get install rsync -yqq \
 && apt-get clean -yqq \
 && rm -rf /var/lib/apt

ENTRYPOINT [ "/usr/local/bin/sync-mirror" ]
