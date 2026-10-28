import 'dart:convert';
import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';

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
  final handler = Pipeline().addMiddleware(logRequests()).addHandler(router.call);

  final server = await serve(handler, ip, port);
  print('Servidor de Jueguito corriendo en http://${server.address.host}:${server.port}');
}