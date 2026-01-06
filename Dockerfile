# Arbitrage Scanner Dockerfile
FROM ruby:3.2-slim

# Install dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    git \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Copy Gemfile first for caching
COPY Gemfile Gemfile.lock ./
RUN bundle install --without development test

# Copy application
COPY . .

# Create log directory
RUN mkdir -p log tmp

# Set environment
ENV APP_ENV=production
ENV RACK_ENV=production

# Default command
CMD ["ruby", "bin/scanner"]
