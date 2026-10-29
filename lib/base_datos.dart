import 'package:sqlite3/sqlite3.dart';
import 'package:bcrypt/bcrypt.dart'; // <-- Importamos bcrypt (ya quitamos dart:convert y crypto)

class BaseDatos {
  late Database _db;

  void inicializar() {
    _db = sqlite3.open('jueguito.db');
    
    _db.execute('''
      CREATE TABLE IF NOT EXISTS usuarios (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        usuario TEXT UNIQUE NOT NULL,
        password_hash TEXT NOT NULL
      );
    ''');
    print('✅ Base de datos SQLite inicializada correctamente.');
  }

  // Intenta registrar un usuario encriptando con Bcrypt y Sal aleatoria
  bool registrarUsuario(String usuario, String password) {
    try {
      // BCrypt.gensalt() crea la protección aleatoria única para este usuario
      final hashSeguro = BCrypt.hashpw(password, BCrypt.gensalt());
      
      final stmt = _db.prepare('INSERT INTO usuarios (usuario, password_hash) VALUES (?, ?)');
      stmt.execute([usuario, hashSeguro]);
      stmt.dispose();
      return true;
    } catch (e) {
      return false; // El usuario ya existe
    }
  }

  // Valida credenciales extrayendo el hash y comparándolo matemáticamente
  Map<String, dynamic>? validarLogin(String usuario, String password) {
    // 1. Buscamos al usuario SOLO por su nombre
    final ResultSet resultados = _db.select(
      'SELECT * FROM usuarios WHERE usuario = ?',
      [usuario]
    );

    if (resultados.isNotEmpty) {
      final usuarioDb = resultados.first;
      final hashGuardado = usuarioDb['password_hash'] as String;
      
      // 2. BCrypt verifica si la contraseña plana coincide con el hash complejo
      if (BCrypt.checkpw(password, hashGuardado)) {
        return usuarioDb; // Las credenciales son correctas
      }
    }
    return null; // Contraseña incorrecta o usuario no encontrado
  }

  // Elimina un usuario de la base de datos a partir de su nombre
  bool borrarUsuario(String usuario) {
    try {
      final stmt = _db.prepare('DELETE FROM usuarios WHERE usuario = ?');
      stmt.execute([usuario]);
      stmt.dispose();
      return true;
    } catch (e) {
      print('Error al borrar usuario: $e');
      return false;
    }
  }
}