import 'dart:convert';
import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';

// 1. Creamos un filtro (Middleware) para darle permiso a los navegadores (CORS)
Middleware permisosCors() {
  return (Handler manejadorInterno) {
    return (Request request) async {
      // Los navegadores primero envían una petición 'OPTIONS' invisible para pedir permiso
      if (request.method == 'OPTIONS') {
        return Response.ok('', headers: {
          'Access-Control-Allow-Origin': '*', // Permitir cualquier origen
          'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
          'Access-Control-Allow-Headers': 'Origin, Content-Type, Authorization',
        });
      }

      // Procesamos la petición normal (ej. el POST a /login)
      final response = await manejadorInterno(request);

      // Le pegamos los permisos a la respuesta final
      return response.change(headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
        'Access-Control-Allow-Headers': 'Origin, Content-Type, Authorization',
      });
    };
  };
}

// Esta es nuestra "llave maestra". Con esto el servidor encripta y desencripta.
// En un futuro la sacaremos de aquí por seguridad, pero por ahora está bien.
const String secretoJWT = 'mi_super_secreto_jueguito_7x7';

void main(List<String> args) async {
  final router = Router();

  // Ruta de prueba para generar un Token (Simulando un Login exitoso)
  router.post('/login', (Request request) async {
    
    // Aquí (más adelante) validaremos en base de datos.
    // Por ahora, si alguien llama a esta ruta, le creamos su token:
    final jwt = JWT({
      'id_jugador': 'jugador_001',
      'nombre': 'Adán',
      'rol': 'usuario'
    });

    // Firmamos el token con nuestro secreto
    final token = jwt.sign(SecretKey(secretoJWT));

    // Respondemos con el token en formato JSON
    return Response.ok(
      jsonEncode({
        'mensaje': 'Login exitoso', 
        'token': token
      }),
      headers: {'Content-Type': 'application/json'},
    );
  });

  // Configuramos el servidor para que escuche en nuestra máquina local
  final ip = InternetAddress.anyIPv4;
  final port = int.parse(Platform.environment['PORT'] ?? '8080');
  
  // Pipeline: Es como un filtro por donde pasan todas las peticiones (aquí solo imprimimos un log en consola)
  final handler = Pipeline().addMiddleware(permisosCors()).addMiddleware(logRequests()).addHandler(router.call);

  final server = await serve(handler, ip, port);
  print('Servidor de Jueguito corriendo en http://${server.address.host}:${server.port}');
}