import 'dart:async'; // EL FIX: Necesario para el Timer de 20 segundos
import 'dart:convert';
import 'dart:math';
import 'package:web_socket_channel/web_socket_channel.dart';

class Jugador {
  final String usuario;
  WebSocketChannel canal; // EL FIX: Le quitamos el 'final' para poder conectarle un cable nuevo si se reconecta
  String? codigoSala;
  bool seRindio = false; // EL FIX: Bandera para diferenciar rendición de caída de red

  Jugador(this.usuario, this.canal);
}

class Sala {
  final String codigo;
  final Jugador anfitrion;
  final List<Jugador> jugadores = [];

  final Map<String, int> zonasReclamadas = {};
  final Set<String> jugadoresListos = {}; 
  final Set<String> jugadoresTerminaronTurno = {};
  bool enJuego = false;
  String mapa; 
  final Map<String, List<int>> turnosZonasReclamadas = {};

  // EL FIX: Aquí guardaremos las "bombas de tiempo" de 20 segundos de cada jugador
  final Map<String, Timer> timersDesconexion = {}; 

  Sala(this.codigo, this.anfitrion, {this.mapa = 'mapa1'}) {
    jugadores.add(anfitrion);
  }

  List<String> obtenerNombresJugadores() {
    return jugadores.map((j) => j.usuario).toList();
  }
}

class GestorSalas {
  final Map<String, Sala> _salas = {};
  final Map<WebSocketChannel, Jugador> _conexionesActivas = {};

  void manejarConexion(WebSocketChannel canal, String usuario) {
    // =======================================================
    // EL FIX: DETECTOR DE RECONEXIONES AUTOMÁTICAS
    // =======================================================
    Sala? salaRecuperada;
    Jugador? jugadorPerdido;

    for (var sala in _salas.values) {
      if (sala.enJuego) {
        try {
          jugadorPerdido = sala.jugadores.firstWhere((j) => j.usuario == usuario);
          salaRecuperada = sala;
          break;
        } catch (_) {}
      }
    }

    if (salaRecuperada != null && jugadorPerdido != null) {
      print('♻️ $usuario se está reconectando a la partida...');
      
      // 1. Le conectamos el cable de red nuevo al jugador viejo
      jugadorPerdido.canal = canal;
      _conexionesActivas[canal] = jugadorPerdido;

      // 2. Desactivamos la bomba de tiempo de 20 segundos
      salaRecuperada.timersDesconexion[usuario]?.cancel();
      salaRecuperada.timersDesconexion.remove(usuario);

      // 3. Lo metemos directamente al tablero saltándose el lobby
      _enviar(canal, {
        'tipo': 'partida_lista',
        'mapa': salaRecuperada.mapa
      });

      // 4. Le avisamos al rival que ya regresó
      _notificarRival(jugadorPerdido, {
        'tipo': 'lobby_actualizado', // Reutilizamos este evento para mostrar el mensaje amarillo
        'mensaje': '¡Tu rival se ha reconectado a la partida!',
        'jugadores': salaRecuperada.obtenerNombresJugadores()
      });
      
    } else {
      // Conexión normal por primera vez
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
  }

  void _procesarMensaje(Jugador jugador, Map<String, dynamic> datos) {
    final accion = datos['accion'];

    switch (accion) {
      case 'crear_sala':
        String codigo = _generarCodigo();
        jugador.codigoSala = codigo;
        final mapaElegido = datos['mapa'] ?? 'mapa1';
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
            _enviar(jugador.canal, {
              'tipo': 'unido_exitosamente',
              'codigo': codigo,
              'mapa': sala.mapa, 
              'anfitrion': sala.anfitrion.usuario,
              'jugadores': sala.obtenerNombresJugadores(),
            });
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

      case 'reclamar_zona':
        final sala = _salas[jugador.codigoSala];
        if (sala != null && sala.enJuego) {
          final idZona = datos['idZona'];
          final turno = datos['turno']; 
          if (!sala.turnosZonasReclamadas.containsKey(idZona)) sala.turnosZonasReclamadas[idZona] = [];
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
          _notificarSala(sala, {'tipo': 'nuevos_dados', 'dado1': Random().nextInt(6) + 1, 'dado2': Random().nextInt(6) + 1});
        }
        break;

      case 'terminar_turno':
        final sala = _salas[jugador.codigoSala];
        if (sala != null && sala.enJuego) {
          sala.jugadoresTerminaronTurno.add(jugador.usuario);
          if (sala.jugadoresTerminaronTurno.length >= sala.jugadores.length) {
            sala.jugadoresTerminaronTurno.clear(); 
            _notificarSala(sala, {'tipo': 'nuevos_dados', 'dado1': Random().nextInt(6) + 1, 'dado2': Random().nextInt(6) + 1});
          }
        }
        break;

      case 'jugada':
        _notificarRival(jugador, datos);
        break;

      case 'declarar_victoria':
        final sala = _salas[jugador.codigoSala];
        if (sala != null && sala.enJuego) {
          _notificarSala(sala, {'tipo': 'fin_de_partida', 'ganador': jugador.usuario, 'puntuacion': datos['puntuacion']});
          _salas.remove(sala.codigo); 
        }
        break;

      case 'rendirse':
        jugador.seRindio = true; // EL FIX: Prendemos la bandera de rendición antes de matarlo
        _manejarDesconexion(jugador);
        break;
    }
  }

  void _manejarDesconexion(Jugador jugador) {
    _conexionesActivas.remove(jugador.canal);
    
    if (jugador.codigoSala != null) {
      final sala = _salas[jugador.codigoSala];
      if (sala != null) {
        
        if (sala.enJuego) {
          // =======================================================
          // EL FIX: ¿RENDICIÓN O CAÍDA DE INTERNET?
          // =======================================================
          if (jugador.seRindio) {
            // SE RINDIÓ: Lo matamos de inmediato y le damos la victoria al otro
            sala.jugadores.remove(jugador);
            _notificarSala(sala, {
              'tipo': 'victoria_por_abandono',
              'mensaje': sala.anfitrion == jugador 
                  ? 'El anfitrión se ha rendido. ¡Victoria por abandono!' 
                  : 'Tu rival ha huido. ¡Has ganado por abandono!'
            });
            _salas.remove(jugador.codigoSala);
          } else {
            // CAÍDA DE INTERNET: Le damos 20 segundos de gracia
            print('⚠️ ${jugador.usuario} perdió conexión. Iniciando timer de 20s...');
            
            _notificarRival(jugador, {
              'tipo': 'lobby_actualizado',
              'mensaje': 'Tu rival se desconectó. Démosle 20 segundos para regresar...',
              'jugadores': sala.obtenerNombresJugadores()
            });

            // Armamos la bomba de tiempo
            sala.timersDesconexion[jugador.usuario] = Timer(const Duration(seconds: 20), () {
              // Si pasan 20 segundos y esta función se ejecuta, significa que no regresó
              print('☠️ Se agotó el tiempo para ${jugador.usuario}. Declarando forfeit.');
              sala.jugadores.remove(jugador);
              _notificarSala(sala, {
                'tipo': 'victoria_por_abandono',
                'mensaje': 'Tu rival perdió la conexión a internet. ¡Has ganado por abandono!'
              });
              _salas.remove(jugador.codigoSala);
            });
          }
        } else {
          // ESTABAN EN EL LOBBY
          sala.jugadores.remove(jugador);
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

  void _notificarSala(Sala sala, Map<String, dynamic> mensaje) {
    final payload = jsonEncode(mensaje);
    for (var j in sala.jugadores) {
      try { j.canal.sink.add(payload); } catch (_) {} 
    }
  }

  void _notificarRival(Jugador jugador, Map<String, dynamic> mensaje) {
    if (jugador.codigoSala == null) return;
    final sala = _salas[jugador.codigoSala];
    if (sala != null) {
      final payload = jsonEncode(mensaje);
      for (var rival in sala.jugadores) {
        if (rival.usuario != jugador.usuario) {
          try { rival.canal.sink.add(payload); } catch (_) {}
        }
      }
    }
  }

  void _enviar(WebSocketChannel canal, Map<String, dynamic> mensaje) {
    try { canal.sink.add(jsonEncode(mensaje)); } catch (_) {}
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