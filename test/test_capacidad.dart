import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

const baseUrl = 'http://127.0.0.1:8080';
const wsUrl = 'ws://127.0.0.1:8080/ws';

// Función auxiliar para registrar/loguear bots automáticamente
Future<String> obtenerToken(String usuario) async {
  final cuerpo = jsonEncode({'usuario': usuario, 'password': '123'});
  
  // 1. Intentamos registrar (si ya existe, el servidor devuelve error pero no pasa nada)
  await http.post(Uri.parse('$baseUrl/registro'), body: cuerpo);
  
  // 2. Iniciamos sesión para robar el Token JWT
  final res = await http.post(Uri.parse('$baseUrl/login'), body: cuerpo);
  return jsonDecode(res.body)['token'];
}

void main() async {
  print('=== INICIANDO SIMULACIÓN DE 7 JUGADORES ===');
  
  // 1. Entra el Anfitrión (Jugador 1)
  String token1 = await obtenerToken('Bot_Anfitrion');
  final canal1 = WebSocketChannel.connect(Uri.parse('$wsUrl?token=$token1'));
  
  String codigoSala = '';
  
  canal1.stream.listen((mensaje) async {
    final datos = jsonDecode(mensaje);
    
    // Si el servidor confirma la creación de la sala
    if (datos['tipo'] == 'sala_creada') {
      codigoSala = datos['codigo'];
      print('✅ Bot_Anfitrion creó la sala: $codigoSala');
      
      // 2. Conectamos 5 jugadores más rápidamente (Bots 2 al 6)
      for (int i = 2; i <= 6; i++) {
        String token = await obtenerToken('Bot_Jugador_$i');
        final canal = WebSocketChannel.connect(Uri.parse('$wsUrl?token=$token'));
        
        canal.sink.add(jsonEncode({'accion': 'unirse_sala', 'codigo': codigoSala}));
        
        canal.stream.listen((msg) {
          final d = jsonDecode(msg);
          if (d['tipo'] == 'unido_exitosamente') {
            print('✅ Bot_Jugador_$i se unió a la sala.');
          }
        });
        await Future.delayed(const Duration(milliseconds: 200));
      }
      
      // 3. Intentamos meter a la fuerza al Jugador 7
      print('---');
      print('⚠️ Intentando infiltrar al Bot_7 (Debe ser rechazado)...');
      String token7 = await obtenerToken('Bot_Jugador_7');
      final canal7 = WebSocketChannel.connect(Uri.parse('$wsUrl?token=$token7'));
      
      canal7.sink.add(jsonEncode({'accion': 'unirse_sala', 'codigo': codigoSala}));
      
      canal7.stream.listen((msg) {
        final d = jsonDecode(msg);
        if (d['tipo'] == 'error') {
          print('❌ RECHAZO EXITOSO: "${d['mensaje']}"');
          print('=== PRUEBA SUPERADA ===');
          exit(0); // Cerramos el script de prueba
        }
      });
    }
  });
  
  // Le pedimos al servidor crear la sala para arrancar la prueba
  canal1.sink.add(jsonEncode({'accion': 'crear_sala'}));
}