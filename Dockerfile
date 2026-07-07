# Stage 1: Build the Dart application
FROM dart:stable AS build

WORKDIR /app
COPY pubspec.* ./
RUN dart pub get

COPY . .
RUN dart compile exe bin/server.dart -o bin/server

# Stage 2: Minimal run image with Python, yt-dlp, and ffmpeg
FROM python:3.11-slim-bookworm

# Install ffmpeg and curl
RUN apt-get update && apt-get install -y ffmpeg curl && rm -rf /var/lib/apt/lists/*

# Install yt-dlp via pip (the most up-to-date source)
RUN pip install --no-cache-dir yt-dlp

# Copy compiled Dart server executable
WORKDIR /app
COPY --from=build /app/bin/server /app/bin/server

# Expose port (Render sets PORT env variable)
EXPOSE 9090

# Start server
CMD ["/app/bin/server"]