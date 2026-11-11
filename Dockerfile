# Usa la imagen oficial de Dart para compilar
FROM dart:stable AS build

WORKDIR /app
COPY pubspec.* ./
RUN dart pub get

COPY . .
RUN dart pub get --offline
RUN dart compile exe bin/server.dart -o bin/server

# Construye la imagen final con Debian
FROM debian:bookworm-slim

# EL FIX: Instalamos sqlite3 y su versión de desarrollo (libsqlite3-dev)
RUN apt-get update && apt-get install -y sqlite3 libsqlite3-dev && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=build /app/bin/server /app/bin/

# Ejecuta el servidor
CMD ["/app/bin/server"]