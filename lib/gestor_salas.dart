import 'dart:convert';
import 'dart:math';
import 'package:web_socket_channel/web_socket_channel.dart';

class Jugador {
  final String usuario;
  final WebSocketChannel canal;
  String? codigoSala;

  Jugador(this.usuario, this.canal);
}

// NUEVO: La clase Sala actúa como el Árbitro de la partida
class Sala {
  final String codigo;
  final Jugador anfitrion;
  final List<Jugador> jugadores = [];

  // ÁRBITRO: Lleva el conteo de cuántas veces se ha reclamado una zona (máximo 3)
  // Ej: {'AM': 1, 'NA1': 3}
  final Map<String, int> zonasReclamadas = {};
  bool enJuego = false;
  
  // NUEVO: La sala recuerda su mapa
  String mapa; 

  // Modificamos el constructor para aceptar el mapa (por defecto mapa1)
  Sala(this.codigo, this.anfitrion, {this.mapa = 'mapa1'}) {
    jugadores.add(anfitrion);
  }

  List<String> obtenerNombresJugadores() {
    return jugadores.map((j) => j.usuario).toList();
  }
}

class GestorSalas {
  // Ahora guardamos objetos Sala completos en lugar de simples listas
  final Map<String, Sala> _salas = {};
  final Map<WebSocketChannel, Jugador> _conexionesActivas = {};

  void manejarConexion(WebSocketChannel canal, String usuario) {
    final jugador = Jugador(usuario, canal);
    _conexionesActivas[canal] = jugador;

    canal.stream.listen(
      (mensaje) {
        try {
          final datos = jsonDecode(mensaje);
          _procesarMensaje(jugador, datos);
        } catch (e) {
          print('Mensaje malformado ignorado: $mensaje');
        }
      },
      onDone: () => _manejarDesconexion(jugador),
      onError: (error) => _manejarDesconexion(jugador),
    );
  }

  void _procesarMensaje(Jugador jugador, Map<String, dynamic> datos) {
    final accion = datos['accion'];

    switch (accion) {
      // ----------------------------------------------------
      // 1. GESTIÓN DEL LOBBY (Hasta 6 jugadores)
      // ----------------------------------------------------
      case 'crear_sala':
        String codigo = _generarCodigo();
        jugador.codigoSala = codigo;
        
        // LEEMOS EL MAPA QUE ELIGIÓ EL ANFITRIÓN (si no manda nada, ponemos mapa1)
        final mapaElegido = datos['mapa'] ?? 'mapa1';
        
        // CREAMOS LA SALA PASÁNDOLE EL MAPA
        final nuevaSala = Sala(codigo, jugador, mapa: mapaElegido);
        _salas[codigo] = nuevaSala;

        _enviar(jugador.canal, {
          'tipo': 'sala_creada',
          'codigo': codigo,
          'mapa': mapaElegido, // Le confirmamos el mapa de vuelta
          'jugadores': nuevaSala.obtenerNombresJugadores()
        });
        break;

      case 'unirse_sala':
        String codigo = (datos['codigo'] as String).toUpperCase();
        final sala = _salas[codigo];

        if (sala != null) {
          if (sala.enJuego) {
            _enviar(jugador.canal, {'tipo': 'error', 'mensaje': 'La partida ya comenzó'});
          } else if (sala.jugadores.length >= 6) {
            _enviar(jugador.canal, {'tipo': 'error', 'mensaje': 'La sala está llena (Máximo 6)'});
          } else {
            jugador.codigoSala = codigo;
            sala.jugadores.add(jugador);
            
            // Le confirmamos al que acaba de entrar
            _enviar(jugador.canal, {
              'tipo': 'unido_exitosamente',
              'codigo': codigo,
              'mapa': sala.mapa, // EL SERVIDOR LE AVISA EL MAPA DE ESTA SALA AL INVITADO
              'anfitrion': sala.anfitrion.usuario,
              'jugadores': sala.obtenerNombresJugadores(),
            });

            // Le avisamos a TODOS los demás que la lista de espera se actualizó
            _notificarSala(sala, {
              'tipo': 'lobby_actualizado',
              'jugadores': sala.obtenerNombresJugadores()
            });
          }
        } else {
          _enviar(jugador.canal, {'tipo': 'error', 'mensaje': 'Código inválido o sala cerrada'});
        }
        break;

      case 'iniciar_partida':
        final sala = _salas[jugador.codigoSala];
        // Solo el anfitrión puede detonar el inicio
        if (sala != null && sala.anfitrion == jugador) {
          if (sala.jugadores.length >= 2) { 
            sala.enJuego = true;
            _notificarSala(sala, {'tipo': 'partida_lista', 'mapa': sala.mapa}); // ¡Arranca el juego para todos!
          } else {
            _enviar(jugador.canal, {'tipo': 'error', 'mensaje': 'Se necesitan al menos 2 jugadores'});
          }
        }
        break;

      // ----------------------------------------------------
      // 2. LÓGICA DE JUEGO (Carrera por las Zonas)
      // ----------------------------------------------------
      case 'reclamar_zona':
        final sala = _salas[jugador.codigoSala];
        if (sala != null) {
          final idZona = datos['idZona'];
          int vecesReclamada = sala.zonasReclamadas[idZona] ?? 0;

          if (vecesReclamada < 3) { // Regla: Solo 3 personas pueden puntuar por zona
            vecesReclamada++;
            sala.zonasReclamadas[idZona] = vecesReclamada;

            // Le gritamos a TODA LA SALA quién reclamó la zona y en qué lugar quedó (1ero, 2do o 3ro)
            // Con esto el frontend sabrá cómo atenuar el color y cuántos puntos darle
            _notificarSala(sala, {
              'tipo': 'zona_reclamada',
              'idZona': idZona,
              'jugador': jugador.usuario,
              'lugar': vecesReclamada 
            });
          } else {
            // Ya se reclamó 3 veces, le avisamos al jugador lento que se quedó sin puntos
            _enviar(jugador.canal, {
              'tipo': 'zona_agotada',
              'idZona': idZona,
              'mensaje': 'Esta zona ya fue reclamada 3 veces por otros jugadores.'
            });
          }
        }
        break;

      case 'tirar_dados':
        // Cuando alguien tira los dados, se los mandamos a todos para que tengan los mismos números
        _notificarSala(_salas[jugador.codigoSala]!, datos);
        break;

      case 'jugada':
        // Reenviamos las jugadas a los demás (por si en el futuro quieres mostrar mini-tableros de los rivales)
        _notificarRival(jugador, datos);
        break;

      case 'rendirse':
        _manejarDesconexion(jugador);
        break;
    }
  }

  void _manejarDesconexion(Jugador jugador) {
    _conexionesActivas.remove(jugador.canal);
    
    if (jugador.codigoSala != null) {
      final sala = _salas[jugador.codigoSala];
      if (sala != null) {
        sala.jugadores.remove(jugador);

        if (sala.jugadores.isEmpty) {
          // Si ya no hay nadie, destruimos la sala
          _salas.remove(jugador.codigoSala);
        } else {
          // Si se va el anfitrión en pleno lobby, cerramos la sala para todos
          if (!sala.enJuego && sala.anfitrion == jugador) {
             _notificarSala(sala, {'tipo': 'error', 'mensaje': 'El anfitrión cerró la sala.'});
             _salas.remove(jugador.codigoSala);
          } else {
             // Si el juego ya empezó o no era el anfitrión, el juego continúa sin él
            _notificarSala(sala, {
              'tipo': sala.enJuego ? 'jugador_desconectado' : 'lobby_actualizado',
              'jugador': jugador.usuario,
              'jugadores': sala.obtenerNombresJugadores(),
              'mensaje': '${jugador.usuario} ha salido de la partida.'
            });
          }
        }
      }
    }
  }

  // Envía un mensaje a TODOS en la sala (incluyendo al que detonó la acción)
  void _notificarSala(Sala sala, Map<String, dynamic> mensaje) {
    final payload = jsonEncode(mensaje);
    for (var j in sala.jugadores) {
      j.canal.sink.add(payload);
    }
  }

  // Envía un mensaje a todos MENOS al que originó la acción
  void _notificarRival(Jugador jugador, Map<String, dynamic> mensaje) {
    if (jugador.codigoSala == null) return;
    
    final sala = _salas[jugador.codigoSala];
    if (sala != null) {
      final payload = jsonEncode(mensaje);
      for (var rival in sala.jugadores) {
        if (rival.usuario != jugador.usuario) {
          rival.canal.sink.add(payload);
        }
      }
    }
  }

  void _enviar(WebSocketChannel canal, Map<String, dynamic> mensaje) {
    canal.sink.add(jsonEncode(mensaje));
  }

  String _generarCodigo() {
    const caracteres = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; 
    final rnd = Random();
    String codigo;
    do {
      codigo = String.fromCharCodes(Iterable.generate(4, (_) => caracteres.codeUnitAt(rnd.nextInt(caracteres.length))));
    } while (_salas.containsKey(codigo));
    return codigo;
  }
}