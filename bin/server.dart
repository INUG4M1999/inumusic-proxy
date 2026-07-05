import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// Proxy CORS local seguro para InuMusic
/// Usa yt-dlp (local) para extraer streams de audio de YouTube
/// Maneja autenticación segura de Spotify y búsquedas en el backend para ocultar credenciales
/// Endpoints:
///   GET /search?q=<query>         -> Busca en YouTube y devuelve resultados
///   GET /stream?title=<t>&artist=<a> -> Obtiene la URL del stream de audio
///   GET /proxy?video=<videoId>    -> Retransmite el stream de audio (con validación de ID)
///   GET /spotify/recommended      -> Obtiene lanzamientos recomendados de Spotify de forma segura
///   GET /spotify/search?q=<q>     -> Busca canciones en Spotify de forma segura
///
/// Corre en http://127.0.0.1:9090

String _youtubeApiKey = '';
String _spotifyClientId = '';
String _spotifyClientSecret = '';
String? _cookiesPath;

// Ruta al ejecutable de yt-dlp (junto al proxy)
String _getYtDlpPath() {
  final localExe = '${Directory.current.path}${Platform.pathSeparator}yt-dlp.exe';
  if (File(localExe).existsSync()) return localExe;

  final localLinux = '${Directory.current.path}${Platform.pathSeparator}yt-dlp';
  if (File(localLinux).existsSync()) return localLinux;

  // Fallback al comando del sistema si está instalado globalmente en Linux/Docker
  return 'yt-dlp';
}

final String _ytDlpPath = _getYtDlpPath();

// Cache de URLs para evitar llamadas repetidas a yt-dlp
final Map<String, _CachedStream> _streamCache = {};

// Cache para tokens de acceso de Spotify
String? _spotifyAccessToken;
DateTime? _spotifyTokenExpiry;

// Cache y base para Rate Limiting
final Map<String, List<DateTime>> _rateLimits = {};

bool _isRateLimited(String ipAddress) {
  final now = DateTime.now();
  final windowStart = now.subtract(const Duration(minutes: 1));
  final timestamps = _rateLimits[ipAddress] ?? [];
  final activeTimestamps = timestamps.where((t) => t.isAfter(windowStart)).toList();
  
  if (activeTimestamps.length >= 30) {
    return true;
  }
  
  activeTimestamps.add(now);
  _rateLimits[ipAddress] = activeTimestamps;
  return false;
}

String _sanitizeQuery(String input) {
  String clean = input.replaceAll('..', '');
  clean = clean.replaceAll('/', '');
  clean = clean.replaceAll('\\', '');
  clean = clean.replaceAll(RegExp(r'[;&|`$]'), '');
  return clean.trim();
}

class _CachedStream {
  final String url;
  final DateTime expiresAt;
  _CachedStream(this.url) : expiresAt = DateTime.now().add(const Duration(minutes: 30));
  bool get isExpired => DateTime.now().isAfter(expiresAt);
}

void main() async {
  // 1. Cargar configuraciones
  await _loadConfig();

  // Escribir cookies si están en la variable de entorno (para evadir bloqueo de bot en la nube)
  final cookiesEnv = Platform.environment['YOUTUBE_COOKIES'];
  if (cookiesEnv != null && cookiesEnv.isNotEmpty) {
    try {
      final file = File('cookies.txt');
      await file.writeAsString(cookiesEnv);
      _cookiesPath = file.path;
      print('✅ Archivo cookies.txt generado con éxito desde la variable de entorno YOUTUBE_COOKIES.');
    } catch (e) {
      print('⚠️ Error al generar cookies.txt: $e');
    }
  }

  // 2. Verificar que yt-dlp existe
  bool exists = false;
  if (File(_ytDlpPath).existsSync()) {
    exists = true;
  } else {
    // Probar si existe en el path del sistema
    try {
      final check = await Process.run(_ytDlpPath, ['--version']);
      if (check.exitCode == 0) {
        exists = true;
      }
    } catch (_) {}
  }

  if (!exists) {
    print('❌ ERROR: yt-dlp no encontrado en: $_ytDlpPath');
    print('   Asegúrate de que el ejecutable esté junto al servidor o instalado en el PATH.');
    exit(1);
  }
  print('✅ yt-dlp verificado.');

  final isProduction = Platform.environment['PORT'] != null;
  final int port = int.tryParse(Platform.environment['PORT'] ?? '') ?? 9090;
  // Si está en producción (Render/Docker) usa 0.0.0.0, si es local se enlaza estrictamente a 127.0.0.1
  final bindAddress = isProduction ? InternetAddress.anyIPv4 : InternetAddress.loopbackIPv4;
  final server = await HttpServer.bind(bindAddress, port);
  print('🎵 InuMusic CORS Proxy corriendo en http://${bindAddress.address}:$port');
  print('   Endpoints:');
  print('   GET /search?q=<query>');
  print('   GET /stream?title=<title>&artist=<artist>');
  print('   GET /proxy?video=<videoId>');
  print('   GET /spotify/recommended');
  print('   GET /spotify/search?q=<query>');

  await for (final request in server) {
    _handleRequest(request);
  }
}

Future<void> _loadConfig() async {
  // Intentar cargar desde variables de entorno primero (Seguro para producción en la nube)
  _youtubeApiKey = Platform.environment['YOUTUBE_API_KEY'] ?? '';
  _spotifyClientId = Platform.environment['SPOTIFY_CLIENT_ID'] ?? '';
  _spotifyClientSecret = Platform.environment['SPOTIFY_CLIENT_SECRET'] ?? '';

  if (_youtubeApiKey.isNotEmpty && _spotifyClientId.isNotEmpty && _spotifyClientSecret.isNotEmpty) {
    print('📦 Configuración cargada con éxito desde las variables de entorno.');
    return;
  }

  // Fallback a config.json (para desarrollo local)
  try {
    final configFile = File('config.json');
    if (configFile.existsSync()) {
      final content = await configFile.readAsString();
      final config = json.decode(content);
      _youtubeApiKey = config['youtube_api_key'] ?? '';
      _spotifyClientId = config['spotify_client_id'] ?? '';
      _spotifyClientSecret = config['spotify_client_secret'] ?? '';
      print('📦 Configuración cargada con éxito desde config.json.');
      return;
    }
    throw Exception('No se encontraron variables de entorno y config.json no existe.');
  } catch (e) {
    print('❌ ERROR cargando configuración: $e');
    print('Asegúrate de definir YOUTUBE_API_KEY, SPOTIFY_CLIENT_ID y SPOTIFY_CLIENT_SECRET en tus variables de entorno o tener un config.json válido.');
    exit(1);
  }
}

Future<String> _getSpotifyAccessToken() async {
  if (_spotifyAccessToken != null && _spotifyTokenExpiry != null && DateTime.now().isBefore(_spotifyTokenExpiry!)) {
    return _spotifyAccessToken!;
  }

  print('🔑 Obteniendo token de acceso de Spotify...');
  final authStr = '$_spotifyClientId:$_spotifyClientSecret';
  final base64Auth = base64Encode(utf8.encode(authStr));

  final response = await http.post(
    Uri.parse('https://accounts.spotify.com/api/token'),
    headers: {
      'Authorization': 'Basic $base64Auth',
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body: 'grant_type=client_credentials',
  );

  if (response.statusCode == 200) {
    final data = json.decode(response.body);
    _spotifyAccessToken = data['access_token'] as String;
    final expiresIn = data['expires_in'] as int? ?? 3600;
    _spotifyTokenExpiry = DateTime.now().add(Duration(seconds: expiresIn - 60)); // Buffer de 60s
    print('🔑 Token obtenido con éxito.');
    return _spotifyAccessToken!;
  } else {
    throw Exception('Error de autenticación con Spotify: ${response.statusCode} ${response.body}');
  }
}

Future<void> _handleRequest(HttpRequest request) async {
  final path = request.uri.path;
  String clientIp = request.headers.value('x-forwarded-for') ?? 
                    request.headers.value('x-real-ip') ?? 
                    request.headers.value('cf-connecting-ip') ?? 
                    request.connectionInfo?.remoteAddress.address ?? 
                    'unknown';
  if (clientIp.contains(',')) {
    clientIp = clientIp.split(',').first.trim();
  }

  // Verificar Rate Limiting (máximo 30 peticiones por minuto, exceptuando /healthz)
  if (path != '/healthz' && _isRateLimited(clientIp)) {
    print('🛑 TASA EXCEDIDA: IP $clientIp bloqueada temporalmente por exceso de peticiones.');
    request.response.statusCode = 429;
    request.response.headers.contentType = ContentType.json;
    request.response.write(json.encode({
      'status': 'error',
      'message': 'Límite de peticiones excedido (máx 30/min). Por favor espera.'
    }));
    await request.response.close();
    return;
  }

  // CORS: Permitir cualquier origen en producción, ya que la firma de seguridad X-InuMusic-Signature valida la autenticidad
  final origin = request.headers.value('origin') ?? '*';
  request.response.headers.add('Access-Control-Allow-Origin', origin);
  request.response.headers.add('Access-Control-Allow-Methods', 'GET, OPTIONS');
  request.response.headers.add('Access-Control-Allow-Headers', 'Origin, X-Requested-With, Content-Type, Accept, X-InuMusic-Signature, X-InuMusic-Timestamp, X-InuMusic-Client');

  if (request.method == 'OPTIONS') {
    request.response.statusCode = 200;
    await request.response.close();
    return;
  }

  // path ya está definido al inicio de _handleRequest
  final params = request.uri.queryParameters;

  // VERIFICACIÓN DE FIRMA ANTI-MALWARE
  // Solo se permiten peticiones con firma válida para evitar que malware/robots consuman la API
  if (path != '/proxy' && path != '/' && path != '/healthz') {
    if (!_verifySignature(request)) {
      request.response.statusCode = 403;
      request.response.headers.contentType = ContentType.json;
      request.response.write(json.encode({
        'status': 'error',
        'message': 'Acceso Prohibido: Firma de seguridad inválida o ausente.'
      }));
      await request.response.close();
      return;
    }
  }

  try {
    if (path == '/search') {
      await _handleSearch(request, params);
    } else if (path == '/stream') {
      await _handleStream(request, params);
    } else if (path == '/proxy') {
      await _handleProxy(request, params);
    } else if (path == '/spotify/recommended') {
      await _handleSpotifyRecommended(request);
    } else if (path == '/spotify/search') {
      await _handleSpotifySearch(request, params);
    } else {
      request.response.statusCode = 404;
      request.response.write('Not Found');
      await request.response.close();
    }
  } catch (e) {
    print('Error: $e');
    try {
      request.response.statusCode = 500;
      request.response.headers.contentType = ContentType.json;
      request.response.write(json.encode({'error': e.toString()}));
      await request.response.close();
    } catch (_) {
      try { await request.response.close(); } catch (_) {}
    }
  }
}

/// Busca en YouTube usando la API oficial
Future<void> _handleSearch(HttpRequest request, Map<String, String> params) async {
  final rawQuery = params['q'] ?? '';
  final query = _sanitizeQuery(rawQuery);
  if (query.isEmpty) {
    request.response.statusCode = 400;
    request.response.write('Missing parameter: q');
    await request.response.close();
    return;
  }

  print('🔍 Buscando en YouTube: $query');
  try {
    final url = Uri.parse('https://www.googleapis.com/youtube/v3/search?part=snippet&maxResults=5&q=${Uri.encodeComponent(query)}&type=video&key=$_youtubeApiKey');
    final response = await http.get(url);
    if (response.statusCode != 200) {
      throw Exception('YouTube API Error: ${response.statusCode} ${response.body}');
    }
    final data = json.decode(response.body);
    final items = <Map<String, dynamic>>[];

    for (final item in data['items']) {
      items.add({
        'id': item['id']['videoId'],
        'title': item['snippet']['title'],
        'author': item['snippet']['channelTitle'],
        'thumbnail': item['snippet']['thumbnails']['high']['url'],
      });
    }

    request.response.headers.contentType = ContentType.json;
    request.response.write(json.encode({'results': items}));
    await request.response.close();
  } catch (e) {
    print('Error en búsqueda: $e');
    request.response.statusCode = 500;
    request.response.write(e.toString());
    await request.response.close();
  }
}

/// Obtiene el video y devuelve la url de retransmisión
Future<void> _handleStream(HttpRequest request, Map<String, String> params) async {
  final rawTitle = params['title'] ?? '';
  final rawArtist = params['artist'] ?? '';
  final title = _sanitizeQuery(rawTitle);
  final artist = _sanitizeQuery(rawArtist);
  if (title.isEmpty) {
    request.response.statusCode = 400;
    request.response.write('Missing parameter: title');
    await request.response.close();
    return;
  }

  print('🎶 Buscando video para: $title - $artist');
  final searchQuery = '$title $artist';

  try {
    final url = Uri.parse('https://www.googleapis.com/youtube/v3/search?part=snippet&maxResults=1&q=${Uri.encodeComponent(searchQuery)}&type=video&key=$_youtubeApiKey');
    final response = await http.get(url);

    if (response.statusCode != 200) {
      throw Exception('YouTube API Error: ${response.statusCode}');
    }

    final data = json.decode(response.body);
    if ((data['items'] as List).isEmpty) {
      request.response.statusCode = 404;
      request.response.write('No results');
      await request.response.close();
      return;
    }

    final item = data['items'][0];
    final videoId = item['id']['videoId'];

    // Obtener la URL de audio real
    final audioUrl = await _getAudioUrl(videoId);
    String streamUrl = '';

    if (audioUrl != null && 
        (audioUrl.contains('cobalt.tools') || 
         audioUrl.contains('piped') || 
         audioUrl.contains('kavin.rocks') || 
         audioUrl.contains('coluble.net') || 
         audioUrl.contains('tokhmi.xyz') || 
         audioUrl.contains('lunar.icu'))) {
      // Es un CDN público con CORS habilitado y soporte de Range nativo, devolver directamente para ahorrar ancho de banda y latencia
      streamUrl = audioUrl;
      print('✅ Video: $videoId -> CDN Directo: $streamUrl');
    } else {
      // Es un stream directo de YouTube con CORS restrictivo, retransmitirlo por nuestro proxy
      final host = request.headers.value('host') ?? 'localhost:9090';
      final proto = request.headers.value('x-forwarded-proto') ?? 'http';
      streamUrl = '$proto://$host/proxy?video=$videoId';
      print('✅ Video: $videoId -> proxy: $streamUrl');
    }

    request.response.headers.contentType = ContentType.json;
    request.response.write(json.encode({
      'streamUrl': streamUrl,
      'title': item['snippet']['title'],
      'author': item['snippet']['channelTitle'],
      'thumbnail': item['snippet']['thumbnails']['high']['url'],
    }));
    await request.response.close();
  } catch (e) {
    print('Error: $e');
    request.response.statusCode = 500;
    request.response.write(e.toString());
    await request.response.close();
  }
}

/// Retransmite el audio al navegador (proxy CORS)
Future<void> _handleProxy(HttpRequest request, Map<String, String> params) async {
  // Añadir CORS específico para el endpoint /proxy (no tiene verificación de firma)
  final origin = request.headers.value('origin') ?? '*';

  final videoId = params['video'] ?? '';
  if (videoId.isEmpty) {
    request.response.statusCode = 400;
    request.response.write('Missing parameter: video');
    await request.response.close();
    return;
  }

  // VALIDACIÓN DE SEGURIDAD ESTRICTA (Previene inyección de parámetros RCE)
  // Los ID de YouTube tienen 11 caracteres y solo contienen A-Za-z0-9_-
  final RegExp ytIdRegExp = RegExp(r'^[a-zA-Z0-9_-]{11}$');
  if (!ytIdRegExp.hasMatch(videoId)) {
    print('🛑 INTENTO DE INYECCIÓN DETECTADO: videoId no válido: "$videoId"');
    request.response.statusCode = 400;
    request.response.headers.contentType = ContentType.json;
    request.response.write(json.encode({'error': 'invalid_parameter', 'message': 'El formato de video es inválido.'}));
    await request.response.close();
    return;
  }

  print('📡 Proxy audio para: $videoId');

  final audioUrl = await _getAudioUrl(videoId);
  if (audioUrl == null) {
    request.response.statusCode = 503;
    request.response.headers.contentType = ContentType.json;
    request.response.write(json.encode({'error': 'no_stream'}));
    await request.response.close();
    return;
  }

  try {
    final client = http.Client();
    final audioRequest = http.Request('GET', Uri.parse(audioUrl));
    
    // Soporte de Range Requests para compatibilidad móvil y Chrome/Safari en producción
    final rangeHeader = request.headers.value('range');
    if (rangeHeader != null) {
      audioRequest.headers['Range'] = rangeHeader;
      print('📡 Solicitud de rango recibida: $rangeHeader');
    }

    // Pasar headers de User-Agent para que YouTube no rechace
    audioRequest.headers['User-Agent'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36';
    final streamedResponse = await client.send(audioRequest).timeout(const Duration(seconds: 30));

    if (streamedResponse.statusCode != 200 && streamedResponse.statusCode != 206) {
      _streamCache.remove(videoId);
      print('  ⚠️ URL expirada o error (status ${streamedResponse.statusCode}), reintentando...');
      
      final newUrl = await _getAudioUrl(videoId, skipYoutubeExplode: true);
      if (newUrl == null) {
        request.response.statusCode = 503;
        await request.response.close();
        client.close();
        return;
      }
      
      final retryRequest = http.Request('GET', Uri.parse(newUrl));
      if (rangeHeader != null) {
        retryRequest.headers['Range'] = rangeHeader;
      }
      retryRequest.headers['User-Agent'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36';
      final retryResponse = await client.send(retryRequest).timeout(const Duration(seconds: 30));
      
      if (retryResponse.statusCode != 200 && retryResponse.statusCode != 206) {
        request.response.statusCode = 503;
        await request.response.close();
        client.close();
        return;
      }
      
      request.response.statusCode = retryResponse.statusCode;
      retryResponse.headers.forEach((name, value) {
        if (name.toLowerCase() == 'content-type' || 
            name.toLowerCase() == 'content-length' || 
            name.toLowerCase() == 'content-range' || 
            name.toLowerCase() == 'accept-ranges') {
          request.response.headers.add(name, value);
        }
      });
      request.response.headers.add('Access-Control-Allow-Origin', origin);
      
      print('📡 Retransmitiendo audio (retry)...');
      await request.response.addStream(retryResponse.stream);
      await request.response.close();
      client.close();
      print('✅ Completado (retry): $videoId');
      return;
    }

    // Configurar respuesta con headers originales (incluyendo Content-Range si es 206)
    request.response.statusCode = streamedResponse.statusCode;
    streamedResponse.headers.forEach((name, value) {
      if (name.toLowerCase() == 'content-type' || 
          name.toLowerCase() == 'content-length' || 
          name.toLowerCase() == 'content-range' || 
          name.toLowerCase() == 'accept-ranges') {
        request.response.headers.add(name, value);
      }
    });
    request.response.headers.add('Access-Control-Allow-Origin', origin);

    print('📡 Retransmitiendo audio (${streamedResponse.contentLength ?? "desconocido"} bytes)...');
    await request.response.addStream(streamedResponse.stream);
    await request.response.close();
    client.close();
    print('✅ Completado: $videoId');
  } catch (e) {
    print('Error retransmitiendo: $e');
    try {
      request.response.statusCode = 500;
      await request.response.close();
    } catch (_) {
      try { await request.response.close(); } catch (_) {}
    }
  }
}

Future<String?> _getCobaltAudioUrl(String videoId) async {
  try {
    print('📡 Intentando extraer audio con Cobalt API para video: $videoId...');
    final response = await http.post(
      Uri.parse('https://api.cobalt.tools/'),
      headers: {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      },
      body: json.encode({
        'url': 'https://www.youtube.com/watch?v=$videoId',
        'downloadMode': 'audio',
        'aFormat': 'mp3',
      }),
    ).timeout(const Duration(seconds: 10));

    if (response.statusCode == 200) {
      final data = json.decode(response.body) as Map<String, dynamic>;
      final streamUrl = data['url'] as String?;
      if (streamUrl != null && streamUrl.isNotEmpty) {
        print('✅ Cobalt API obtuvo con éxito la URL del stream.');
        return streamUrl;
      }
    }
    print('⚠️ Cobalt API falló (status ${response.statusCode}): ${response.body}');
  } catch (e) {
    print('⚠️ Excepción en Cobalt API: $e');
  }
  return null;
}

Future<String?> _getPipedAudioUrl(String videoId) async {
  final instances = [
    'https://pipedapi.kavin.rocks',
    'https://pipedapi.coluble.net',
    'https://pipedapi.tokhmi.xyz',
    'https://api.piped.yt',
    'https://piped-api.lunar.icu',
  ];

  for (final api in instances) {
    try {
      print('📡 Intentando extraer audio con Piped API ($api) para video: $videoId...');
      final response = await http.get(
        Uri.parse('$api/streams/$videoId'),
      ).timeout(const Duration(seconds: 6));

      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        final audioStreams = data['audioStreams'] as List<dynamic>?;
        if (audioStreams != null && audioStreams.isNotEmpty) {
          final url = audioStreams.first['url'] as String?;
          if (url != null && url.isNotEmpty) {
            print('✅ Piped API ($api) obtuvo con éxito la URL del stream.');
            return url;
          }
        }
      }
      print('⚠️ Piped API ($api) retornó status ${response.statusCode}');
    } catch (e) {
      print('⚠️ Excepción en Piped API ($api): $e');
    }
  }
  return null;
}

Future<String?> _getAudioUrl(String videoId, {bool skipYoutubeExplode = false}) async {
  final cached = _streamCache[videoId];
  if (cached != null && !cached.isExpired) {
    return cached.url;
  }

  if (!skipYoutubeExplode) {
    print('📡 Getting stream URL using youtube_explode for video: $videoId...');
    final yt = YoutubeExplode();
    try {
      final manifest = await yt.videos.streamsClient.getManifest(videoId);
      final streamInfo = manifest.audioOnly.withHighestBitrate();
      final url = streamInfo.url.toString();
      if (url.isNotEmpty && url.startsWith('http')) {
        print('✅ youtube_explode successfully retrieved stream URL.');
        _streamCache[videoId] = _CachedStream(url);
        return url;
      }
    } catch (e) {
      print('⚠️ youtube_explode failed: $e. Falling back...');
    } finally {
      yt.close();
    }
  }

  // Cobalt API
  final cobaltUrl = await _getCobaltAudioUrl(videoId);
  if (cobaltUrl != null) {
    _streamCache[videoId] = _CachedStream(cobaltUrl);
    return cobaltUrl;
  }

  // Piped API
  final pipedUrl = await _getPipedAudioUrl(videoId);
  if (pipedUrl != null) {
    _streamCache[videoId] = _CachedStream(pipedUrl);
    return pipedUrl;
  }

  // yt-dlp
  final clients = ['default', 'web', 'android', 'ios', 'mweb'];
  for (final client in clients) {
    print('📡 Running yt-dlp for video: $videoId with player_client=$client...');
    try {
      final args = [
        '-f', 'bestaudio[ext=m4a]/bestaudio',
        '--get-url',
        if (_cookiesPath != null) ...['--cookies', _cookiesPath!],
      ];
      if (client != 'default') {
        args.addAll(['--extractor-args', 'youtube:player_client=$client']);
      }
      args.add('https://www.youtube.com/watch?v=$videoId');

      final result = await Process.run(
        _ytDlpPath,
        args,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );

      print('📡 yt-dlp ($client) exit code: ${result.exitCode}');
      if (result.exitCode == 0) {
        final url = (result.stdout as String).trim();
        if (url.isNotEmpty && url.startsWith('http')) {
          print('✅ yt-dlp ($client) successfully retrieved stream URL.');
          _streamCache[videoId] = _CachedStream(url);
          return url;
        }
      }
    } catch (e) {
      print('❌ Exception running yt-dlp ($client): $e');
    }
  }
  return null;
}

/// Obtiene los lanzamientos recomendados de Spotify de forma segura (con fallback a iTunes si falla)
Future<void> _handleSpotifyRecommended(HttpRequest request) async {
  print('📻 Consultando Spotify: Lanzamientos recomendados...');
  List<Map<String, String>> tracks = [];
  bool success = false;

  try {
    final token = await _getSpotifyAccessToken();
    final response = await http.get(
      Uri.parse('https://api.spotify.com/v1/browse/new-releases?limit=10'),
      headers: {'Authorization': 'Bearer $token'},
    );

    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      final albums = data['albums']['items'] as List<dynamic>;

      for (final album in albums) {
        String coverUrl = '';
        final images = album['images'] as List<dynamic>?;
        if (images != null && images.isNotEmpty) {
          coverUrl = images.first['url'] ?? '';
        }
        final artists = (album['artists'] as List<dynamic>)
            .map((e) => e['name'] as String)
            .join(', ');

        tracks.add({
          'title': album['name'] ?? 'Sin Título',
          'artist': artists,
          'coverUrl': coverUrl,
          'album': album['name'] ?? 'Sin Álbum',
        });
      }
      success = true;
    } else {
      print('⚠️ Spotify recommended falló (${response.statusCode}): ${response.body}');
    }
  } catch (e) {
    print('⚠️ Error en spotify/recommended, intentando fallback de iTunes: $e');
  }

  // Fallback a iTunes Popular Releases si Spotify falla o está restringido
  if (!success) {
    print('📻 Usando iTunes API como fallback para recomendados...');
    try {
      final response = await http.get(
        Uri.parse('https://itunes.apple.com/search?term=pop&media=music&limit=12'),
      );
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final results = data['results'] as List<dynamic>;
        for (final item in results) {
          String cover = (item['artworkUrl100'] as String?)?.replaceAll('100x100', '600x600') ?? '';
          tracks.add({
            'title': item['trackName'] ?? 'Sin Título',
            'artist': item['artistName'] ?? 'Artista Desconocido',
            'coverUrl': cover,
            'album': item['collectionName'] ?? 'Sin Álbum',
          });
        }
      }
    } catch (e) {
      print('❌ Fallback de iTunes también falló: $e');
    }
  }

  request.response.headers.contentType = ContentType.json;
  request.response.write(json.encode({'tracks': tracks}));
  await request.response.close();
}

/// Busca canciones en Spotify de forma segura (con fallback a iTunes si falla)
Future<void> _handleSpotifySearch(HttpRequest request, Map<String, String> params) async {
  final rawQuery = params['q'] ?? '';
  final query = _sanitizeQuery(rawQuery);
  if (query.isEmpty) {
    request.response.statusCode = 400;
    request.response.write('Missing parameter: q');
    await request.response.close();
    return;
  }

  print('🔍 Buscando: $query');
  List<Map<String, String>> tracks = [];
  bool success = false;

  try {
    final token = await _getSpotifyAccessToken();
    final encodedQuery = Uri.encodeComponent(query);
    final response = await http.get(
      Uri.parse('https://api.spotify.com/v1/search?q=$encodedQuery&type=track&limit=10'),
      headers: {'Authorization': 'Bearer $token'},
    );

    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      final items = data['tracks']['items'] as List<dynamic>;

      for (final item in items) {
        String coverUrl = '';
        final album = item['album'] as Map<String, dynamic>?;
        if (album != null) {
          final images = album['images'] as List<dynamic>?;
          if (images != null && images.isNotEmpty) {
            coverUrl = images.first['url'] ?? '';
          }
        }
        final artists = (item['artists'] as List<dynamic>)
            .map((e) => e['name'] as String)
            .join(', ');

        tracks.add({
          'title': item['name'] ?? 'Sin Título',
          'artist': artists,
          'coverUrl': coverUrl,
          'album': album?['name'] ?? 'Sin Álbum',
          'previewUrl': item['preview_url'] ?? '',
        });
      }
      success = true;
    } else {
      print('⚠️ Spotify search falló (${response.statusCode}): ${response.body}');
    }
  } catch (e) {
    print('⚠️ Error en spotify/search, intentando fallback de iTunes: $e');
  }

  // Fallback a iTunes Search si Spotify falla o está restringido
  if (!success) {
    print('🔍 Usando iTunes API como fallback para búsqueda de "$query"...');
    try {
      final encodedQuery = Uri.encodeComponent(query);
      final response = await http.get(
        Uri.parse('https://itunes.apple.com/search?term=$encodedQuery&media=music&limit=12'),
      );
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final results = data['results'] as List<dynamic>;
        for (final item in results) {
          String cover = (item['artworkUrl100'] as String?)?.replaceAll('100x100', '600x600') ?? '';
          tracks.add({
            'title': item['trackName'] ?? 'Sin Título',
            'artist': item['artistName'] ?? 'Artista Desconocido',
            'coverUrl': cover,
            'album': item['collectionName'] ?? 'Sin Álbum',
            'previewUrl': item['previewUrl'] ?? '',
          });
        }
      }
    } catch (e) {
      print('❌ Fallback de iTunes también falló: $e');
    }
  }

  request.response.headers.contentType = ContentType.json;
  request.response.write(json.encode({'tracks': tracks}));
  await request.response.close();
}

bool _verifySignature(HttpRequest request) {
  // Clave de seguridad idéntica a la del cliente
  const List<int> secureKeyBytes = [
    73, 110, 117, 77, 117, 115, 105, 99, 83, 101, 99, 117, 114, 101, 83, 104, 105, 101, 108, 100, 84, 111, 107, 101, 110, 50, 48, 50, 54
  ];
  final String secureKey = String.fromCharCodes(secureKeyBytes);

  try {
    final signature = request.headers.value('X-InuMusic-Signature');
    final timestampStr = request.headers.value('X-InuMusic-Timestamp');
    final client = request.headers.value('X-InuMusic-Client');

    if (signature == null || timestampStr == null || client != 'InuMusicSecureClientFlutter') {
      print('🔒 Saludo de seguridad rechazado: Faltan cabeceras de firma en la ruta "${request.uri.path}" (Signature: $signature, Timestamp: $timestampStr, Client: $client).');
      return false;
    }

    final int timestamp = int.parse(timestampStr);
    final int now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    // Aumentar la tolerancia a 15 minutos (900 segundos) para mitigar el desfase de reloj (NTP/Docker/Timezone) en servidores en la nube
    if ((now - timestamp).abs() > 900) {
      print('🔒 Saludo de seguridad rechazado: Firma caducada por ${ (now - timestamp).abs() } segundos (tolerancia 900s).');
      return false;
    }

    // Desofuscar firma XOR
    final List<int> signatureBytes = base64.decode(signature);
    final List<int> decryptedBytes = List<int>.generate(signatureBytes.length, (i) {
      return signatureBytes[i] ^ secureKeyBytes[i % secureKeyBytes.length];
    });
    final String decryptedPayload = utf8.decode(decryptedBytes);

    final List<String> parts = decryptedPayload.split('|');
    if (parts.length != 3) return false;

    final String path = parts[0];
    final String time = parts[1];
    final String key = parts[2];

    final String actualPathQuery = request.uri.path + (request.uri.hasQuery ? "?${request.uri.query}" : "");
    final String cleanPathQuery = Uri.decodeComponent(actualPathQuery);
    final String cleanPayloadPathQuery = Uri.decodeComponent(path);

    if (cleanPathQuery == cleanPayloadPathQuery && time == timestampStr && key == secureKey) {
      return true;
    }

    print('🔒 Saludo de seguridad rechazado: Firma corrupta o no coincide con la URI solicitada.');
    return false;
  } catch (e) {
    print('🔒 Saludo de seguridad rechazado: Error al verificar firma: $e');
    return false;
  }
}
