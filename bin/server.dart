import 'dart:convert';
import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';

// Importa tus clases locales usando 'package:'
import 'package:servidor_jueguito/base_datos.dart'; 
import 'package:servidor_jueguito/gestor_salas.dart';

// --- VARIABLES GLOBALES ---
// NOTA: Si usabas otro texto para tu secreto, pon el tuyo aquí
const String secretoJWT = 'mi_secreto_super_seguro'; 

final db = BaseDatos();
final gestorSalas = GestorSalas();

// --- SISTEMA ANTI FUERZA BRUTA ---
final Map<String, int> intentosFallidos = {};
final Map<String, DateTime> cuentasBloqueadas = {};

void main(List<String> args) async {
  final router = Router();

  // ==========================================
  // 1. RUTA DE REGISTRO
  // ==========================================
  router.post('/registro', (Request request) async {
    try {
      final cuerpo = await request.readAsString();
      final datos = jsonDecode(cuerpo);
      final usuario = datos['usuario'];
      final password = datos['password'];

      final exito = db.registrarUsuario(usuario, password);

      if (exito) {
        return Response.ok(jsonEncode({'mensaje': 'Usuario registrado correctamente'}));
      } else {
        return Response.forbidden(jsonEncode({'error': 'El usuario ya existe'}));
      }
    } catch (e) {
      return Response.internalServerError(body: jsonEncode({'error': 'Error interno del servidor'}));
    }
  });

  // ==========================================
  // 2. RUTA DE LOGIN (Con Anti Fuerza Bruta)
  // ==========================================
  router.post('/login', (Request request) async {
    try {
      final cuerpo = await request.readAsString();
      final datos = jsonDecode(cuerpo);
      final usuario = datos['usuario'];
      final password = datos['password'];

      // TRAMPA ANTI-HACKERS: ¿El usuario está bloqueado?
      if (cuentasBloqueadas.containsKey(usuario)) {
        final tiempoDesbloqueo = cuentasBloqueadas[usuario]!;
        if (DateTime.now().isBefore(tiempoDesbloqueo)) {
          return Response.forbidden(jsonEncode({
            'error': 'Demasiados intentos fallidos. Intenta de nuevo en 15 minutos.'
          }));
        } else {
          cuentasBloqueadas.remove(usuario);
          intentosFallidos.remove(usuario);
        }
      }

      // Validar en SQLite
      final usuarioDb = db.validarLogin(usuario, password);

      if (usuarioDb != null) {
        intentosFallidos.remove(usuario); // Borramos historial de fallos

        final jwt = JWT({
          'id_jugador': usuarioDb['id'],
          'nombre': usuarioDb['usuario'],
          'rol': 'jugador'
        });

        final token = jwt.sign(
          SecretKey(secretoJWT),
          expiresIn: const Duration(days: 7),
        );

        return Response.ok(
          jsonEncode({'mensaje': 'Login exitoso', 'token': token}),
          headers: {'Content-Type': 'application/json'},
        );
      } else {
        intentosFallidos[usuario] = (intentosFallidos[usuario] ?? 0) + 1;

        if (intentosFallidos[usuario]! >= 5) {
          cuentasBloqueadas[usuario] = DateTime.now().add(const Duration(minutes: 15));
          return Response.forbidden(jsonEncode({
            'error': 'Has fallado 5 veces. Cuenta bloqueada por seguridad durante 15 minutos.'
          }));
        }

        final intentosRestantes = 5 - intentosFallidos[usuario]!;
        return Response(401, body: jsonEncode({
          'error': 'Usuario o contraseña incorrectos. Intentos restantes: $intentosRestantes'
        }));
      }
    } catch (e) {
      return Response.internalServerError(body: jsonEncode({'error': 'Error interno del servidor'}));
    }
  });

  // ==========================================
  // 3. RUTA PARA BORRAR CUENTA (Protegida con JWT)
  // ==========================================
  router.delete('/borrar-cuenta', (Request request) async {
    try {
      final authHeader = request.headers['Authorization'];
      if (authHeader == null || !authHeader.startsWith('Bearer ')) {
        return Response.forbidden(jsonEncode({'error': 'Token no proporcionado'}));
      }

      final token = authHeader.substring(7);
      final jwt = JWT.verify(token, SecretKey(secretoJWT));
      
      final idJugador = jwt.payload['id_jugador'];

      final exito = db.borrarUsuario(idJugador);

      if (exito) {
        return Response.ok(jsonEncode({'mensaje': 'Cuenta borrada exitosamente'}));
      } else {
        return Response.internalServerError(body: jsonEncode({'error': 'No se pudo borrar la cuenta'}));
      }
    } catch (e) {
      return Response.forbidden(jsonEncode({'error': 'Token inválido o caducado'}));
    }
  });

  // ==========================================
  // 4. ENDPOINT MULTIJUGADOR (WEBSOCKETS)
  // ==========================================
  router.get('/ws', (Request request) async {
    final token = request.url.queryParameters['token'];

    if (token == null) {
      return Response.forbidden(jsonEncode({'error': 'Token no proporcionado'}));
    }

    String usuarioJugador;
    try {
      // Usamos el JWT para garantizar que nadie pueda entrar al socket sin autenticarse
      final jwt = JWT.verify(token, SecretKey(secretoJWT));
      usuarioJugador = jwt.payload['nombre'];
    } catch (e) {
      return Response.forbidden(jsonEncode({'error': 'Token inválido o expirado'}));
    }

    // Elevamos la conexión HTTP a un túnel de WebSockets
    final handler = webSocketHandler((webSocket, _) {  // <--- Agregamos la coma y el guion bajo aquí
      gestorSalas.manejarConexion(webSocket, usuarioJugador);
    });

    return await handler(request);
  });

  // ==========================================
  // INICIAR EL SERVIDOR
  // ==========================================
  final handler = const Pipeline().addMiddleware(logRequests()).addHandler(router.call);
  
  // Usamos anyIPv4 para que pueda escuchar peticiones locales (localhost / 127.0.0.1) y del emulador (10.0.2.2)
  final server = await io.serve(handler, InternetAddress.anyIPv4, 8080);
  print('Servidor corriendo en http://${server.address.host}:${server.port}');
}