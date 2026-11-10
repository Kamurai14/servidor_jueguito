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

# ESTO ES VITAL: Instalamos la librería de SQLite3 en la máquina de Render
RUN apt-get update && apt-get install -y libsqlite3-0 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=build /app/bin/server /app/bin/

# Ejecuta el servidor
CMD ["/app/bin/server"]