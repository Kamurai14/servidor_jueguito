import 'dart:convert';
import 'dart:math';
import 'package:web_socket_channel/web_socket_channel.dart';

class Jugador {
  final String usuario;
  final WebSocketChannel canal;
  String? codigoSala;

  Jugador(this.usuario, this.canal);
}

// La clase Sala actúa como el Árbitro de la partida
class Sala {
  final String codigo;
  final Jugador anfitrion;
  final List<Jugador> jugadores = [];

  // ÁRBITRO: Lleva el conteo de cuántas veces se ha reclamado una zona (máximo 3)
  // Ej: {'AM': 1, 'NA1': 3}
  final Map<String, int> zonasReclamadas = {};
  final Set<String> jugadoresListos = {}; // Para saber quién ya puso sus 6 piezas
  final Set<String> jugadoresTerminaronTurno = {};
  bool enJuego = false;
  
  // La sala recuerda su mapa
  String mapa; 
  // Para llevar el historial de empates -> Ejemplo: 'AM': [5, 8]
  final Map<String, List<int>> turnosZonasReclamadas = {};

  // Constructor para aceptar el mapa (por defecto mapa1)
  Sala(this.codigo, this.anfitrion, {this.mapa = 'mapa1'}) {
    jugadores.add(anfitrion);
  }

  List<String> obtenerNombresJugadores() {
    return jugadores.map((j) => j.usuario).toList();
  }
}

class GestorSalas {
  // Guardamos objetos Sala completos
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
          'mapa': mapaElegido, 
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
              'mapa': sala.mapa, 
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
        if (sala != null && sala.anfitrion == jugador) {
          if (sala.jugadores.length >= 2) { 
            sala.enJuego = true;
            _notificarSala(sala, {'tipo': 'partida_lista', 'mapa': sala.mapa}); 
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
        if (sala != null && sala.enJuego) {
          final idZona = datos['idZona'];
          final turno = datos['turno']; 

          if (!sala.turnosZonasReclamadas.containsKey(idZona)) {
            sala.turnosZonasReclamadas[idZona] = [];
          }
          
          final turnosDeEstaZona = sala.turnosZonasReclamadas[idZona]!;
          
          if (!turnosDeEstaZona.contains(turno)) {
            turnosDeEstaZona.add(turno);
            turnosDeEstaZona.sort(); 
          }
          
          final lugar = turnosDeEstaZona.indexOf(turno) + 1;

          _notificarSala(sala, {
            'tipo': 'zona_reclamada',
            'idZona': idZona,
            'lugar': lugar,
            'usuario': jugador.usuario
          });
        }
        break;

      case 'listo_para_jugar':
        final sala = _salas[jugador.codigoSala];
        if (sala != null) {
          sala.jugadoresListos.add(jugador.usuario);
          _notificarSala(sala, {
            'tipo': 'actualizacion_listos',
            'listos': sala.jugadoresListos.length,
            'total': sala.jugadores.length
          });
        }
        break;

      case 'tirar_dados':
        final sala = _salas[jugador.codigoSala];
        if (sala != null && sala.anfitrion == jugador) {
          final d1 = Random().nextInt(6) + 1;
          final d2 = Random().nextInt(6) + 1;
          
          _notificarSala(sala, {
            'tipo': 'nuevos_dados',
            'dado1': d1,
            'dado2': d2
          });
        }
        break;

      case 'terminar_turno':
        final sala = _salas[jugador.codigoSala];
        if (sala != null && sala.enJuego) {
          sala.jugadoresTerminaronTurno.add(jugador.usuario);
          
          if (sala.jugadoresTerminaronTurno.length >= sala.jugadores.length) {
            sala.jugadoresTerminaronTurno.clear(); 
            
            final d1 = Random().nextInt(6) + 1;
            final d2 = Random().nextInt(6) + 1;
            
            _notificarSala(sala, {
              'tipo': 'nuevos_dados',
              'dado1': d1,
              'dado2': d2
            });
          }
        }
        break;

      case 'jugada':
        _notificarRival(jugador, datos);
        break;

      case 'declarar_victoria':
        final sala = _salas[jugador.codigoSala];
        if (sala != null && sala.enJuego) {
          _notificarSala(sala, {
            'tipo': 'fin_de_partida',
            'ganador': jugador.usuario,
            'puntuacion': datos['puntuacion']
          });
          _salas.remove(sala.codigo); 
        }
        break;

      case 'rendirse':
        _manejarDesconexion(jugador);
        break;
    }
  }

  // =======================================================
  // PARAMÉDICO DE RED: MANEJO DE DESCONEXIONES
  // =======================================================
  void _manejarDesconexion(Jugador jugador) {
    _conexionesActivas.remove(jugador.canal);
    
    if (jugador.codigoSala != null) {
      final sala = _salas[jugador.codigoSala];
      if (sala != null) {
        
        // EL FIX: Primero eliminamos físicamente al jugador de la sala ANTES de hacer cálculos
        sala.jugadores.remove(jugador);

        if (sala.enJuego) {
          // EL JUEGO YA EMPEZÓ
          // Si el que se fue era el anfitrión, o si ya solo queda 1 jugador vivo (o ninguno)
          if (sala.anfitrion == jugador || sala.jugadores.length < 2) {
            
            _notificarSala(sala, {
              'tipo': 'victoria_por_abandono',
              'mensaje': sala.anfitrion == jugador 
                  ? 'El anfitrión huyó cobardemente. ¡Victoria para los sobrevivientes!' 
                  : 'Todos tus rivales han huido. ¡Has ganado por abandono!'
            });
            _salas.remove(jugador.codigoSala);
            
          } else {
            // Si huye un invitado pero la partida era de 3 a 6 jugadores, el juego sigue
            sala.jugadoresListos.remove(jugador.usuario);
            sala.jugadoresTerminaronTurno.remove(jugador.usuario);

            _notificarSala(sala, {
              'tipo': 'jugador_abandono',
              'usuario': jugador.usuario,
              'jugadores': sala.obtenerNombresJugadores(),
              'total': sala.jugadores.length,
            });

            // Rescate de turno atascado por si estábamos esperando a que el que huyó pasara turno
            if (sala.jugadoresTerminaronTurno.length >= sala.jugadores.length) {
              sala.jugadoresTerminaronTurno.clear();
              _notificarSala(sala, {
                'tipo': 'nuevos_dados',
                'dado1': Random().nextInt(6) + 1,
                'dado2': Random().nextInt(6) + 1
              });
            }
          }
        } else {
          // ESTABAN EN EL LOBBY
          if (sala.anfitrion == jugador) {
            _notificarSala(sala, {'tipo': 'sala_cerrada', 'razon': 'El anfitrión cerró la sala.'});
            _salas.remove(jugador.codigoSala);
          } else {
            if (sala.jugadores.isEmpty) {
              _salas.remove(jugador.codigoSala);
            } else {
              _notificarSala(sala, {
                'tipo': 'lobby_actualizado',
                'jugadores': sala.obtenerNombresJugadores()
              });
            }
          }
        }
      }
    }
  }

  // Envía un mensaje a TODOS en la sala (incluyendo al que detonó la acción)
  void _notificarSala(Sala sala, Map<String, dynamic> mensaje) {
    final payload = jsonEncode(mensaje);
    for (var j in sala.jugadores) {
      try {
        j.canal.sink.add(payload);
      } catch (_) {} // ESCUDO: Si el celular está apagado, lo ignora y el servidor no crashea
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
          try {
            rival.canal.sink.add(payload);
          } catch (_) {}
        }
      }
    }
  }

  void _enviar(WebSocketChannel canal, Map<String, dynamic> mensaje) {
    try {
      canal.sink.add(jsonEncode(mensaje));
    } catch (_) {}
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