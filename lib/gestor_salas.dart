import 'dart:convert';
import 'dart:math';
import 'package:web_socket_channel/web_socket_channel.dart';

class Jugador {
  final String usuario;
  final WebSocketChannel canal;
  String? codigoSala;

  Jugador(this.usuario, this.canal);
}

class GestorSalas {
  // Llave: Código de 4 caracteres, Valor: Lista de 1 o 2 Jugadores
  final Map<String, List<Jugador>> _salas = {};
  
  // Mapa de rastreo rápido para desconexiones súbitas
  final Map<WebSocketChannel, Jugador> _conexionesActivas = {};

  void manejarConexion(WebSocketChannel canal, String usuario) {
    final jugador = Jugador(usuario, canal);
    _conexionesActivas[canal] = jugador;

    // Escuchamos los mensajes entrantes de este socket
    canal.stream.listen(
      (mensaje) {
        try {
          final datos = jsonDecode(mensaje);
          _procesarMensaje(jugador, datos);
        } catch (e) {
          print('Mensaje malformado ignorado: $mensaje');
        }
      },
      // Si el internet del jugador falla o cierra la app, esto salta de inmediato
      onDone: () => _manejarDesconexion(jugador),
      onError: (error) => _manejarDesconexion(jugador),
    );
  }

  void _procesarMensaje(Jugador jugador, Map<String, dynamic> datos) {
    final accion = datos['accion'];

    switch (accion) {
      case 'crear_sala':
        String codigo = _generarCodigo();
        jugador.codigoSala = codigo;
        _salas[codigo] = [jugador];
        _enviar(jugador.canal, {'tipo': 'sala_creada', 'codigo': codigo});
        break;

      case 'unirse_sala':
        String codigo = (datos['codigo'] as String).toUpperCase();
        if (_salas.containsKey(codigo)) {
          if (_salas[codigo]!.length >= 2) {
            _enviar(jugador.canal, {'tipo': 'error', 'mensaje': 'La sala ya está llena'});
          } else {
            jugador.codigoSala = codigo;
            _salas[codigo]!.add(jugador);
            
            // Notificamos a ambos que la partida inicia. 
            // El creador de la sala siempre empieza el primer turno.
            final creador = _salas[codigo]![0];
            _enviar(creador.canal, {'tipo': 'partida_lista', 'rival': jugador.usuario, 'esTurno': true});
            _enviar(jugador.canal, {'tipo': 'partida_lista', 'rival': creador.usuario, 'esTurno': false});
          }
        } else {
          _enviar(jugador.canal, {'tipo': 'error', 'mensaje': 'Código inválido o sala cerrada'});
        }
        break;

      case 'jugada':
      case 'rendirse':
        // Reenviamos el movimiento (o rendición) intacto al rival
        _notificarRival(jugador, datos);
        
        // Destruimos la sala si alguien se rinde para liberar memoria
        if (accion == 'rendirse') {
          _cerrarSala(jugador.codigoSala);
        }
        break;
    }
  }

  void _manejarDesconexion(Jugador jugador) {
    _conexionesActivas.remove(jugador.canal);
    
    if (jugador.codigoSala != null) {
      // Si estaba a media partida, otorgamos victoria técnica al rival por error de red
      _notificarRival(jugador, {
        'tipo': 'rival_desconectado', 
        'mensaje': 'El rival ha perdido la conexión. ¡Victoria técnica!'
      });
      _cerrarSala(jugador.codigoSala);
    }
  }

  void _notificarRival(Jugador jugador, Map<String, dynamic> mensaje) {
    if (jugador.codigoSala == null) return;
    
    final sala = _salas[jugador.codigoSala];
    if (sala != null) {
      for (var rival in sala) {
        if (rival.usuario != jugador.usuario) {
          _enviar(rival.canal, mensaje);
        }
      }
    }
  }

  void _cerrarSala(String? codigo) {
    if (codigo != null && _salas.containsKey(codigo)) {
      _salas.remove(codigo);
    }
  }

  void _enviar(WebSocketChannel canal, Map<String, dynamic> mensaje) {
    canal.sink.add(jsonEncode(mensaje));
  }

  String _generarCodigo() {
    // Evitamos O, 0, I, 1 para evitar errores de lectura en las invitaciones
    const caracteres = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; 
    final rnd = Random();
    String codigo;
    do {
      codigo = String.fromCharCodes(Iterable.generate(4, (_) => caracteres.codeUnitAt(rnd.nextInt(caracteres.length))));
    } while (_salas.containsKey(codigo));
    return codigo;
  }
}