import 'package:sqlite3/sqlite3.dart';
import 'dart:convert';
import 'package:crypto/crypto.dart';

class BaseDatos {
  late Database _db;

  void inicializar() {
    // Crea o abre un archivo físico llamado 'jueguito.db' en tu servidor
    _db = sqlite3.open('jueguito.db');
    
    // Creamos la tabla de usuarios si no existe
    _db.execute('''
      CREATE TABLE IF NOT EXISTS usuarios (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        usuario TEXT UNIQUE NOT NULL,
        password_hash TEXT NOT NULL
      );
    ''');
    print('✅ Base de datos SQLite inicializada correctamente.');
  }

  // Encripta la contraseña usando SHA-256 (NUNCA guardamos contraseñas en texto plano)
  String _hashearPassword(String password) {
    var bytes = utf8.encode(password);
    var digest = sha256.convert(bytes);
    return digest.toString();
  }

  // Intenta registrar un usuario. Retorna false si el nombre ya está tomado.
  bool registrarUsuario(String usuario, String password) {
    try {
      final hash = _hashearPassword(password);
      final stmt = _db.prepare('INSERT INTO usuarios (usuario, password_hash) VALUES (?, ?)');
      stmt.execute([usuario, hash]);
      stmt.dispose();
      return true;
    } catch (e) {
      // Si el usuario ya existe, SQLite lanzará un error por la restricción "UNIQUE"
      return false; 
    }
  }

  // Valida credenciales. Retorna los datos del usuario si es correcto, o null si falla.
  Map<String, dynamic>? validarLogin(String usuario, String password) {
    final hash = _hashearPassword(password);
    
    final ResultSet resultados = _db.select(
      'SELECT * FROM usuarios WHERE usuario = ? AND password_hash = ?',
      [usuario, hash]
    );

    if (resultados.isNotEmpty) {
      return resultados.first;
    }
    return null; 
  }
}