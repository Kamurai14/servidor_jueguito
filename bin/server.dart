import 'dart:convert';
import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';

// Importamos nuestra nueva base de datos
import 'package:servidor_jueguito/base_datos.dart';

const String secretoJWT = 'mi_super_secreto_jueguito_7x7';

// Instanciamos la base de datos globalmente para que las rutas la usen
final db = BaseDatos();

Middleware permisosCors() {
  return (Handler manejadorInterno) {
    return (Request request) async {
      if (request.method == 'OPTIONS') {
        return Response.ok('', headers: {
          'Access-Control-Allow-Origin': '*',
          'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
          'Access-Control-Allow-Headers': 'Origin, Content-Type, Authorization',
        });
      }
      final response = await manejadorInterno(request);
      return response.change(headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
        'Access-Control-Allow-Headers': 'Origin, Content-Type, Authorization',
      });
    };
  };
}

void main(List<String> args) async {
  // Inicializamos SQLite antes de arrancar el servidor
  db.inicializar();

  final router = Router();

  // 1. RUTA DE REGISTRO
  router.post('/registro', (Request request) async {
    try {
      // Leemos los datos que nos mandó Flutter
      final cuerpo = await request.readAsString();
      final datos = jsonDecode(cuerpo);
      final usuario = datos['usuario'];
      final password = datos['password'];

      if (usuario == null || password == null || usuario.isEmpty || password.isEmpty) {
        return Response.badRequest(body: jsonEncode({'error': 'Faltan datos'}));
      }

      // Intentamos guardarlo en SQLite
      bool exito = db.registrarUsuario(usuario, password);

      if (exito) {
        return Response.ok(jsonEncode({'mensaje': 'Usuario creado exitosamente'}));
      } else {
        // Código 409: Conflicto (el usuario ya existe)
        return Response(409, body: jsonEncode({'error': 'El nombre de usuario ya está en uso'}));
      }
    } catch (e) {
      return Response.internalServerError(body: jsonEncode({'error': 'Error interno del servidor'}));
    }
  });

  // 2. RUTA DE LOGIN ACTUALIZADA
  router.post('/login', (Request request) async {
    try {
      final cuerpo = await request.readAsString();
      final datos = jsonDecode(cuerpo);
      final usuario = datos['usuario'];
      final password = datos['password'];

      // Validamos contra SQLite
      final usuarioDb = db.validarLogin(usuario, password);

      if (usuarioDb != null) {
        // Si las credenciales son correctas, generamos su Token
        final jwt = JWT({
          'id_jugador': usuarioDb['id'],
          'nombre': usuarioDb['usuario'],
          'rol': 'jugador'
        });

        // Firmamos el token y le damos 7 días de vida
        final token = jwt.sign(SecretKey(secretoJWT),expiresIn: const Duration(days: 7),);

        return Response.ok(
          jsonEncode({'mensaje': 'Login exitoso', 'token': token}),
          headers: {'Content-Type': 'application/json'},
        );
      } else {
        // Código 401: No autorizado (credenciales incorrectas)
        return Response(401, body: jsonEncode({'error': 'Usuario o contraseña incorrectos'}));
      }
    } catch (e) {
      return Response.internalServerError(body: jsonEncode({'error': 'Error interno del servidor'}));
    }
  });

  // 3. RUTA PARA BORRAR CUENTA
  router.delete('/borrar-cuenta', (Request request) async {
    try {
      // 1. Verificamos que traiga el token en los headers
      final authHeader = request.headers['authorization'];
      if (authHeader == null || !authHeader.startsWith('Bearer ')) {
        return Response.forbidden(jsonEncode({'error': 'Acceso denegado: Token no proporcionado'}));
      }

      // 2. Extraemos el token (quitando "Bearer ")
      final token = authHeader.substring(7);

      // 3. Desencriptamos usando tu llave secreta
      final jwt = JWT.verify(token, SecretKey(secretoJWT));
      
      // 4. Obtenemos el nombre. En tu login usaste la llave 'nombre' para el payload
      final nombreUsuario = jwt.payload['nombre'];

      // 5. Lo eliminamos de SQLite
      bool exito = db.borrarUsuario(nombreUsuario);

      if (exito) {
        return Response.ok(
          jsonEncode({'mensaje': 'Cuenta eliminada exitosamente'}),
          headers: {'Content-Type': 'application/json'},
        );
      } else {
        return Response.internalServerError(
          body: jsonEncode({'error': 'Error al eliminar el usuario en la base de datos'})
        );
      }
    } catch (e) {
      // Si el JWT.verify falla (token alterado o expirado), cae aquí
      return Response.forbidden(jsonEncode({'error': 'Token inválido o expirado'}));
    }
  });

  final ip = InternetAddress.anyIPv4;
  final port = int.parse(Platform.environment['PORT'] ?? '8080');
  
  final handler = Pipeline()
      .addMiddleware(permisosCors())
      .addMiddleware(logRequests())
      .addHandler(router.call);

  final server = await serve(handler, ip, port);
  print('Servidor de Jueguito corriendo en http://${server.address.host}:${server.port}');
}