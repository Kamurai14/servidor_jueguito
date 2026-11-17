import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:web_socket_channel/web_socket_channel.dart';

class Jugador {
  final String usuario;
  WebSocketChannel canal;
  String? codigoSala;
  bool seRindio = false;
  List<dynamic> tablero = []; 
  int puntuacion = 0;
  
  Jugador(this.usuario, this.canal);
}

class Sala {
  final String codigo;
  final Jugador anfitrion;
  final List<Jugador> jugadores = [];

  final Map<String, int> zonasReclamadas = {};
  
  // Usamos el objeto Jugador para identificar conexiones reales, no nombres
  final Set<Jugador> jugadoresListos = {}; 
  final Set<Jugador> jugadoresTerminaronTurno = {};
  
  bool enJuego = false;
  String mapa; 
  final Map<String, List<int>> turnosZonasReclamadas = {};
  
  final List<Map<String, dynamic>> zonasReclamadasEnEsteTurno = []; 
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
      jugadorPerdido.canal = canal;
      _conexionesActivas[canal] = jugadorPerdido;

      salaRecuperada.timersDesconexion[usuario]?.cancel();
      salaRecuperada.timersDesconexion.remove(usuario);

      _enviar(canal, {
        'tipo': 'partida_lista',
        'mapa': salaRecuperada.mapa
      });

      _notificarRival(jugadorPerdido, {
        'tipo': 'lobby_actualizado',
        'mensaje': 'Tu rival se ha reconectado a la partida',
        'jugadores': salaRecuperada.obtenerNombresJugadores()
      });
      
    } else {
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
          
          sala.zonasReclamadasEnEsteTurno.add({
            'idZona': idZona,
            'lugar': lugar,
            'usuario': jugador.usuario
          });
        }
        break;

      case 'listo_para_jugar':
        final sala = _salas[jugador.codigoSala];
        if (sala != null) {
          sala.jugadoresListos.add(jugador);
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
          jugador.tablero = datos['tablero'] ?? [];
          jugador.puntuacion = datos['puntuacion'] ?? 0;
          
          sala.jugadoresTerminaronTurno.add(jugador);

          if (sala.jugadoresTerminaronTurno.length >= sala.jugadores.length) {
            sala.jugadoresTerminaronTurno.clear(); 
            
            Map<String, dynamic> tableros = {};
            Map<String, int> puntuaciones = {};
            for(var j in sala.jugadores) {
              tableros[j.usuario] = j.tablero;
              puntuaciones[j.usuario] = j.puntuacion;
            }

            _notificarSala(sala, {
              'tipo': 'resumen_turno',
              'dado1': Random().nextInt(6) + 1,
              'dado2': Random().nextInt(6) + 1,
              'tableros': tableros,
              'puntuaciones': puntuaciones,
              'avisos_zonas': sala.zonasReclamadasEnEsteTurno
            });
            
            sala.zonasReclamadasEnEsteTurno.clear();
          }
        }
        break;

      case 'jugada':
        _notificarRival(jugador, datos);
        break;

      case 'declarar_victoria':
        final sala = _salas[jugador.codigoSala];
        if (sala != null && sala.enJuego) {
          List<Map<String, dynamic>> ranking = sala.jugadores.map((j) => {
            'usuario': j.usuario,
            'puntuacion': j.puntuacion,
            'tablero': j.tablero
          }).toList();
          
          ranking.sort((a, b) => (b['puntuacion'] as int).compareTo(a['puntuacion'] as int));

          _notificarSala(sala, {
            'tipo': 'fin_de_partida', 
            'ranking': ranking
          });
          _salas.remove(sala.codigo); 
        }
        break;

      case 'rendirse':
        jugador.seRindio = true; 
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
          if (jugador.seRindio) {
            sala.jugadores.remove(jugador);
            sala.jugadoresListos.remove(jugador);
            sala.jugadoresTerminaronTurno.remove(jugador);
            
            _notificarSala(sala, {
              'tipo': 'victoria_por_abandono',
              'mensaje': sala.anfitrion == jugador 
                  ? 'El anfitrión se ha rendido. Victoria por abandono' 
                  : 'Tu rival ha huido. Has ganado por abandono'
            });
            _salas.remove(jugador.codigoSala);
          } else {
            _notificarRival(jugador, {
              'tipo': 'lobby_actualizado',
              'mensaje': 'Tu rival se desconectó. Démosle 20 segundos para regresar...',
              'jugadores': sala.obtenerNombresJugadores()
            });

            sala.timersDesconexion[jugador.usuario] = Timer(const Duration(seconds: 20), () {
              sala.jugadores.remove(jugador);
              sala.jugadoresListos.remove(jugador);
              sala.jugadoresTerminaronTurno.remove(jugador);
              
              _notificarSala(sala, {
                'tipo': 'victoria_por_abandono',
                'mensaje': 'Tu rival perdió la conexión a internet. Has ganado por abandono'
              });
              _salas.remove(jugador.codigoSala);
            });
          }
        } else {
          sala.jugadores.remove(jugador);
          sala.jugadoresListos.remove(jugador);
          sala.jugadoresTerminaronTurno.remove(jugador);
          
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